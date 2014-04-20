=begin
    Copyright 2010-2014 Tasos Laskos <tasos.laskos@gmail.com>
    All rights reserved.
=end

require 'watir-webdriver'
require_relative 'watir/element'
require_relative 'browser/element_locator'
require_relative 'browser/javascript'

module Arachni

# @note Depends on PhantomJS 1.9.2.
#
# Real browser driver providing DOM/JS/AJAX support.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
class Browser
    include UI::Output
    include Utilities

    personalize_output

    # {Browser} error namespace.
    #
    # All {Browser} errors inherit from and live under it.
    #
    # @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
    class Error < Arachni::Error

        # Raised when a given resource can't be loaded.
        #
        # @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
        class Load < Error
        end
    end

    # How much time to wait for the PhantomJS process to spawn before respawning.
    PHANTOMJS_SPAWN_TIMEOUT = 4

    # How much time to wait for a targeted HTML element to appear on the page
    # after the page is loaded.
    ELEMENT_APPEARANCE_TIMEOUT = 5

    # Let the browser take as long as it needs to complete an operation.
    WATIR_COM_TIMEOUT = 3600 # 1 hour.

    HTML_IDENTIFIERS = ['<!doctype html', '<html', '<head', '<body', '<title', '<script']

    # @return   [Array<Page::DOM::Transition>]
    attr_reader :transitions

    # @return   [Hash]   Preloaded resources, by URL.
    attr_reader :preloads

    # @return   [Watir::Browser]   Watir driver interface.
    attr_reader :watir

    # @return   [Array<Page>]
    #   Same as {#page_snapshots} but it doesn't deduplicate and only contains
    #   pages with sink ({Page::DOM#data_flow_sink} or {Page::DOM#execution_flow_sink})
    #   data as populated by {Javascript#data_flow_sink} and {Javascript#execution_flow_sink}.
    #
    # @see Javascript#data_flow_sink
    # @see Javascript#execution_flow_sink
    # @see Page::DOM#data_flow_sink
    # @see Page::DOM#execution_flow_sink
    attr_reader :page_snapshots_with_sinks

    # @return   [Javascript]
    attr_reader :javascript

    # @return   [Support::LookUp::HashSet]
    #   States that have been visited and should be skipped.
    #
    # @see #skip_state
    # @see #skip_state?
    attr_reader :skip_states

    # @return   [Integer]
    attr_reader :phantomjs_pid

    # @return   [Bool]
    #   `true` if `phantomjs` is in the OS PATH, `false` otherwise.
    def self.has_executable?
        return @has_executable if !@has_executable.nil?
        @has_executable = !!Selenium::WebDriver::PhantomJS.path
    end

    # @param    [Hash]  options
    # @option options   [Integer]    :concurrency
    #   Maximum number of concurrent connections.
    # @option   options [Bool] :store_pages  (true)
    #   Whether to store pages in addition to just passing them to {#on_new_page}.
    def initialize( options = {} )
        @options = options.dup
        @mutex   = Mutex.new

        @proxy = HTTP::ProxyServer.new(
            concurrency:      @options[:concurrency],
            address:          '127.0.0.1',
            request_handler:  proc do |request, response|
                synchronize { exception_jail { request_handler( request, response ) } }
            end,
            response_handler: proc do |request, response|
                synchronize { exception_jail { response_handler( request, response ) } }
            end
        )

        @options[:store_pages] = true if !@options.include?( :store_pages )

        @proxy.start_async

        @watir = ::Watir::Browser.new( *phantomjs )

        # User-controlled response cache, by URL.
        @cache = Support::Cache::LeastRecentlyUsed.new( 200 )

        # User-controlled preloaded responses, by URL.
        @preloads = {}

        # Captured pages -- populated by #capture.
        @captured_pages = []

        # Snapshots of the working page resulting from firing of events and
        # clicking of JS links.
        @page_snapshots = {}

        # Same as @page_snapshots but it doesn't deduplicate and only contains
        # pages with sink (Page::DOM#sink) data as populated by Javascript#flush_sink.
        @page_snapshots_with_sinks = []

        # Captures HTTP::Response objects per URL for open windows.
        @window_responses = {}

        # Keeps track of resources which should be skipped -- like already fired
        # events and clicked links etc.
        @skip_states = Support::LookUp::HashSet.new( hasher: :persistent_hash )

        @transitions = []
        @request_transitions = []
        @add_request_transitions = true

        @on_new_page_blocks = []
        @on_new_page_with_sink_blocks = []
        @on_response_blocks = []
        @on_fire_event_blocks = []

        # Last loaded URL.
        @last_url = nil

        @javascript = Javascript.new( self )

        ensure_open_window
    end

    def source_with_line_numbers
        source.lines.map.with_index do |line, i|
            "#{i+1} - #{line}"
        end.join
    end

    def on_new_page( &block )
        fail ArgumentError, 'Missing block.' if !block_given?
        @on_new_page_blocks << block
    end

    def on_new_page_with_sink( &block )
        fail ArgumentError, 'Missing block.' if !block_given?
        @on_new_page_with_sink_blocks << block
    end

    def on_fire_event( &block )
        fail ArgumentError, 'Missing block.' if !block_given?
        @on_fire_event_blocks << block
    end

    def on_response( &block )
        fail ArgumentError, 'Missing block.' if !block_given?
        @on_response_blocks << block
    end

    # @param    [String, HTTP::Response, Page]  resource
    #   Loads the given resource in the browser. If it is a string it will be
    #   treated like a URL.
    #
    # @return   [Browser]   `self`
    def load( resource, options = {} )
        @last_dom_url = nil

        case resource
            when String
                goto resource, options

            when HTTP::Response
                goto preload( resource ), options

            when Page
                HTTP::Client.update_cookies resource.cookiejar

                @transitions = resource.dom.transitions.dup
                skip_states.merge resource.dom.skip_states

                @last_dom_url = resource.dom.url

                @add_request_transitions = false if @transitions.any?
                resource.dom.restore self
                @add_request_transitions = true

            else
                fail Error::Load,
                     "Can't load resource of type #{resource.class}."
        end

        self
    end

    # @note The preloaded resource will be removed once used, for a persistent
    #   cache use {#cache}.
    #
    # @param    [HTTP::Response, Page]  resource
    #   Preloads a resource to be instantly available by URL via {#load}.
    def preload( resource )
        response =  case resource
                        when HTTP::Response
                            resource

                        when Page
                            resource.response

                        else
                            fail Error::Load,
                                 "Can't load resource of type #{resource.class}."
                    end

        save_response( response ) if !response.url.include?( request_token )

        @preloads[response.url] = response
        response.url
    end

    # @param    [HTTP::Response, Page]  resource
    #   Cache a resource in order to be instantly available by URL via {#load}.
    def cache( resource = nil )
        return @cache if !resource

        response =  case resource
                        when HTTP::Response
                            resource

                        when Page
                            resource.response

                        else
                            fail Error::Load,
                                 "Can't load resource of type #{resource.class}."
                    end

        save_response response
        @cache[response.url] = response
        response.url
    end

    # @param    [String]  url
    #   Loads the given URL in the browser.
    # @param    [Hash]  options
    # @option  [Bool]  :take_snapshot  (true)
    #   Take a snapshot right after loading the page.
    # @option  [Array<Cookie>]  :cookies  ([])
    #   Extra cookies to pass to the webapp.
    #
    # @return   [Page::DOM::Transition]
    #   Transition used to replay the resource visit.
    def goto( url, options = {} )
        take_snapshot = options.include?(:take_snapshot) ?
            options[:take_snapshot] : true
        extra_cookies = options[:cookies] || []

        @last_url = url

        ensure_open_window

        load_cookies url, extra_cookies

        transition = Page::DOM::Transition.new( :page, :load,
            url:     url,
            cookies: extra_cookies
        ) do
            watir.goto url

            @javascript.wait_till_ready
            wait_for_timers
            wait_for_pending_requests
        end

        if @add_request_transitions
            @transitions << transition
        end

        HTTP::Client.update_cookies cookies

        # Capture the page at its initial state.
        capture_snapshot if take_snapshot

        transition
    end

    def close_windows
        watir.cookies.clear
        clear_responses

        @javascript.run( 'window.open()' )
        watir.windows.last.use

        watir.windows[0...-1].each { |w| w.close rescue nil }
    end

    def shutdown
        watir.close
        kill_phantomjs
        @proxy.shutdown
    end

    # @return   [String]    Current URL.
    def url
        normalize_url watir.url
    end

    # Explores the browser's DOM tree and captures page snapshots for each
    # state change until there are no more available.
    #
    # @param    [Integer]   depth How deep to go into the DOM tree.
    # @return   [Array<Page>]   Page snapshots for each state.
    def explore_and_flush( depth = nil )
        pages         = [ to_page ]
        done          = false
        current_depth = 0

        while !done do
            bcnt   = pages.size
            pages |= pages.map { |p| load( p ).trigger_events.flush_pages }.flatten

            if pages.size == bcnt || (depth && depth >= current_depth)
                done = true
                break
            end

            current_depth += 1
        end

        pages.compact
    end

    def skip_state?( state )
        skip_states.include? state
    end

    def skip_state( state )
        skip_states << state
    end

    # @note Will skip non-visible elements as they can't be manipulated.
    #
    # Iterates over all elements which have events and passes their info to the
    # given block.
    #
    # @param    [Bool]  skip_states
    #   Mark each element/events as visited and skip it if it has already been
    #   seen.
    #
    # @yield [ElementLocator,Array<Symbol>]
    #   Hash with information about the element, its tag name, applicable events
    #   along with their handlers and attributes.
    def each_element_with_events( skip_states = true )
        current_url = url

        javascript.dom_elements_with_events.each do |element|
            tag_name   = element['tag_name']
            attributes = element['attributes']
            events     = element['events']

            case tag_name
                when 'a'
                    href = attributes['href'].to_s

                    if !href.empty?
                        if href.start_with?( 'javascript:' )
                            events << [ :click, href ]
                        else
                            next if skip_path?( to_absolute( href, current_url ) )
                        end
                    end

                when 'input'
                    if attributes['type'].to_s.downcase == 'image'
                        events << [ :click, 'image' ]
                    end

                when 'form'
                    action = attributes['action'].to_s

                    if !action.empty?
                        if action.start_with?( 'javascript:' )
                            events << [ :submit, action ]
                        else
                            next if skip_path?( to_absolute( action, current_url ) )
                        end
                    end
            end

            state = "#{tag_name}#{attributes}#{events}"
            next if events.empty? || (skip_states && skip_state?( state ))
            skip_state state if skip_states

            yield ElementLocator.new( tag_name: tag_name, attributes: attributes ),
                    events
        end

        self
    end

    # @return   [String]
    #   Snapshot ID used to determine whether or not a page snapshot has already
    #   been seen. Uses both elements and their DOM events and possible audit
    #   workload to determine the ID, as page snapshots should be retained both
    #   when further browser analysis can be performed and when new element
    #   audit workload (but possibly without any DOM relevance) is available.
    def snapshot_id
        current_url = url

        id = []
        javascript.dom_elements_with_events.each do |element|
            tag_name   = element['tag_name']
            attributes = element['attributes']
            events     = element['events']

            case tag_name
                when 'a'
                    href = attributes['href'].to_s

                    if !href.empty?
                        if href.start_with?( 'javascript:' )
                            events << [ :click, href ]
                        else
                            absolute = to_absolute( href, current_url )
                            if !skip_path?( absolute )
                                events << [ :click, absolute ]
                            end
                        end
                    else
                        events << [ :click, current_url ]
                    end

                when 'input', 'textarea', 'select'
                    events << [ tag_name.to_sym ]

                when 'form'
                    action = attributes['action'].to_s

                    if !action.empty?
                        if action.start_with?( 'javascript:' )
                            events << [ :submit, action ]
                        else
                            absolute = to_absolute( action, current_url )
                            if !skip_path?( absolute )
                                events << [ :submit, absolute ]
                            end
                        end
                    else
                        events << [ :submit, current_url ]
                    end
            end

            next if events.empty?
            id << "#{tag_name}#{attributes}#{events}".hash
        end

        id.sort.to_s
    end

    # Triggers all events on all elements (**once**) and captures
    # {#page_snapshots page snapshots}.
    #
    # @return   [Browser]   `self`
    def trigger_events
        root_page = to_page

        each_element_with_events do |locator, events|
            events.each do |name, _|
                distribute_event( root_page, locator, name.to_sym )
            end
        end

        self
    end

    # @note Only used when running as part of {BrowserCluster} to distribute
    #   page analysis across a pool of browsers.
    #
    # Distributes the triggering of `event` on the element at `element_index`
    # on `page`.
    #
    # @param    [Page]    page
    # @param    [ElementLocator]  locator
    # @param    [Symbol]  event
    def distribute_event( page, locator, event )
        trigger_event( page, locator, event )
    end

    # @note Captures page {#page_snapshots}.
    #
    # Triggers `event` on the element described by `tag` on `page`.
    #
    # @param    [Page]    page  Page containing the element's `tag`.
    # @param    [ElementLocator]  element
    # @param    [Symbol]  event Event to trigger.
    def trigger_event( page, element, event )
        event = event.to_sym
        transition = fire_event( element, event )

        if !transition
            print_info "Could not trigger '#{event}' on '#{element}' because" <<
                ' the page has changed, capturing a new snapshot.'
            capture_snapshot

            print_info 'Restoring page.'
            restore page
            return
        end

        capture_snapshot( transition ).each do |snapshot|
            print_debug "Found new page variation by triggering '#{event}' on: #{element}"
            print_debug 'Page transitions:'
            snapshot.dom.transitions.each { |t| print_debug "-- #{t}" }
        end

        restore page
    end

    # Triggers `event` on `element`.
    #
    # @param    [Watir::Element, ElementLocator]  element
    # @param    [Symbol]  event
    # @param    [Hash]  options
    # @option options [Hash<Symbol,String=>String>]  :inputs
    #   Values to use to fill-in inputs. Keys should be input names or ids.
    #
    #   Defaults to using {Support::KeyFiller} if not specified.
    #
    # @return   [Page::DOM::Transition, false]
    #   Transition if the operation was successful, `nil` otherwise.
    def fire_event( element, event, options = {} )
        event   = event.to_s.downcase.sub( /^on/, '' ).to_sym
        locator = nil

        options[:inputs] = options[:inputs].stringify if options[:inputs]

        if element.is_a? ElementLocator
            locator = element

            begin
                element = element.locate( self )
            rescue Selenium::WebDriver::Error::UnknownError,
                Watir::Exception::UnknownObjectException => e

                print_error "Element '#{locator}' disappeared while triggering '#{event}'."
                print_error
                print_error e
                print_error_backtrace e

                print_info 'Could not trigger event because the page has changed' <<
                               ', capturing a new snapshot.'
                return
            end
        end

        # The page may need a bit to settle and the element is lazily located
        # by Watir so give it a few tries.
        begin
            with_timeout ELEMENT_APPEARANCE_TIMEOUT do
                sleep 0.1 while !element.exists?
            end
        rescue Timeout::Error
            return
        end

        return if !element.visible?

        if locator
            opening_tag = locator.to_s
            tag_name    = locator.tag_name
        else
            opening_tag = element.opening_tag
            tag_name    = element.tag_name
            locator     = ElementLocator.from_html( opening_tag )
        end

        tag_name = tag_name.to_sym

        call_on_fire_event_blocks( element, event )

        tries = 0
        begin
            transition = Page::DOM::Transition.new( locator, event, options ) do
                had_special_trigger = false

                if tag_name == :form
                    element.text_fields.each do |input|
                        value = options[:inputs] ?
                            options[:inputs][name_or_id_for( input )] :
                            value_for( input )

                        input.set( value.to_s )
                    end

                    if event == :submit
                        had_special_trigger = true
                        element.submit
                    end

                elsif tag_name == :input && event == :click &&
                        element.attribute_value(:type) == 'image'

                    had_special_trigger = true
                    watir.button( type: 'image' ).click

                elsif [:keyup, :keypress, :keydown, :change, :input, :focus, :blur, :select].include? event

                    # Some of these need an explicit event triggers.
                    had_special_trigger = true if ![:change, :blur, :focus, :select].include? event

                    element.send_keys( (options[:value] || value_for( element )).to_s )
                end

                element.fire_event( event ) if !had_special_trigger
                wait_for_pending_requests
            end

            prune_window_responses

            transition
        rescue Selenium::WebDriver::Error::UnknownError,
            Watir::Exception::UnknownObjectException => e

            sleep 0.1

            tries += 1
            retry if tries < 5

            print_error "Error when triggering event for: #{url}"
            print_error "-- '#{event}' on: #{opening_tag}"
            print_error
            print_error
            print_error e
            print_error_backtrace e

            nil
        end
    end

    # Starts capturing requests and parses them into elements of pages,
    # accessible via {#captured_pages}.
    #
    # @return   [Browser]   `self`
    #
    # @see #stop_capture
    # @see #capture?
    # @see #captured_pages
    # @see #flush_pages
    def start_capture
        @capture = true
        self
    end

    # Stops the {HTTP::Request} capture.
    #
    # @return   [Browser]   `self`
    #
    # @see #start_capture
    # @see #capture?
    # @see #flush_pages
    def stop_capture
        @capture = false
        self
    end

    # @return   [Bool]
    #   `true` if request capturing is enabled, `false` otherwise.
    #
    # @see #start_capture
    # @see #stop_capture
    def capture?
        !!@capture
    end

    # @return   [Array<Page>]
    #   Page snapshots (stored after events have been fired and JS links clicked)
    #   with hashes as keys and pages as values.
    def page_snapshots
        @page_snapshots.values
    end

    # @return   [Array<Page>]
    #   Captured HTTP requests performed by the web page (AJAX etc.) converted
    #   into forms of pages to assist with analysis and audit.
    def captured_pages
        @captured_pages
    end

    # @return   [Page]  Converts the current browser window to a {Page page}.
    def to_page
        return if !(r = response)

        page         = r.to_page
        page.body    = source

        page.dom.url                 = watir.url
        page.dom.digest              = @javascript.dom_digest
        page.dom.execution_flow_sink = @javascript.execution_flow_sink
        page.dom.data_flow_sink      = @javascript.data_flow_sink
        page.dom.transitions         = @transitions.dup
        page.dom.skip_states         = @skip_states.dup

        page
    end

    def capture_snapshot( transition = nil )
        pages = []

        request_transitions = flush_request_transitions
        transitions = ([transition] + request_transitions).flatten.compact

        begin
            # Skip about:blank windows.
            watir.windows( url: /^http/ ).each do |window|
                window.use do
                    next if !(page = to_page)

                    if pages.empty?
                        transitions.each do |t|
                            @transitions << t
                            page.dom.push_transition t
                        end
                    end

                    capture_snapshot_with_sink( page )

                    unique_id = self.snapshot_id
                    next if skip_state? unique_id
                    skip_state unique_id

                    call_on_new_page_blocks( page )

                    if store_pages?
                        @page_snapshots[unique_id.hash] = page
                        pages << page
                    end
                end
            end
        rescue => e
            print_error "Could not capture snapshot for: #{@last_url}"

            if transition
                print_error "-- #{transition}"
            end

            print_error
            print_error e
            print_error_backtrace e
        end

        pages
    end

    # @return   [Array<Page>]
    #   Returns {#page_snapshots_with_sinks} and flushes it.
    def flush_page_snapshots_with_sinks
        @page_snapshots_with_sinks.dup
    ensure
        @page_snapshots_with_sinks.clear
    end

    # @return   [Array<Page>]
    #   Flushes and returns the {#captured_pages captured} and
    #   {#page_snapshots snapshot} pages.
    #
    # @see #captured_pages
    # @see #page_snapshots
    # @see #start_capture
    # @see #stop_capture
    # @see #capture?
    def flush_pages
        captured_pages + page_snapshots
    ensure
        @captured_pages.clear
        @page_snapshots.clear
    end

    # @return   [Array<Cookie>]   Browser cookies.
    def cookies
        watir.cookies.to_a.map do |c|
            c[:path]  = '/' if c[:path] == '//'
            c[:name]  = Cookie.decode( c[:name].to_s )
            c[:value] = Cookie.decode( c[:value].to_s )

            Cookie.new c.merge( url: @last_url )
        end
    end

    # @return   [String]   HTML code of the evaluated (DOM/JS/AJAX) page.
    def source
        watir.html
    end

    def html?
        response.headers.content_type.to_s.start_with? 'text/html'
    end

    def load_delay
        #(intervals + timeouts).map { |t| t.last }.max
        @javascript.timeouts.map { |t| t.last }.max
    end

    def wait_for_timers
        delay = load_delay
        return if !delay
        sleep delay / 1000.0
    end

    def response
        u = url

        return if skip_path?( u )

        begin
            with_timeout Options.http.request_timeout / 1_000 do
                while !(r = get_response( u ))
                    sleep 0.1
                end

                fail Timeout::Error if r.timed_out?

                return r
            end
        rescue Timeout::Error
            print_error "Response for '#{u}' never arrived."
        end

        nil
    end

    # @return   [Selenium::WebDriver::Driver]   Selenium driver interface.
    def selenium
        return @selenium if @selenium

        client = Selenium::WebDriver::Remote::Http::Default.new
        client.timeout = WATIR_COM_TIMEOUT

        @selenium = Selenium::WebDriver.for(
            :remote,

            # We need to spawn our own PhantomJS process because Selenium's
            # way sometimes gives us zombies.
            url:                  spawn_phantomjs,
            desired_capabilities: capabilities,
            http_client:          client
        )
    end

    private

    def prune_window_responses
        open_windows_urls = watir.windows.map { |w| normalize_url w.url }
        synchronize do
            @window_responses.reject! do |url, _|
                !open_windows_urls.include? url
            end
        end
    end

    def name_or_id_for( element )
        name = element.attribute_value(:name).to_s
        return name if !name.empty?

        id = element.attribute_value(:id).to_s
        return id if !id.empty?

        nil
    end

    def with_timeout( timeout, &block )
        Timeout.timeout( timeout ) do
            block.call
        end
    #rescue
        #ap 'TIMEOUT'
        #ap caller
        #raise
    end

    # @param    [Watir::HTMLElement]    element
    # @return   [String]
    #   Value to use to fill-in the input.
    #
    # @see Support::KeyFiller.name_to_value
    def value_for( element )
        Support::KeyFiller.name_to_value( name_or_id_for( element ), '1' )
    end

    def spawn_phantomjs
        return @phantomjs_url if @phantomjs_url

        ppid = Process.pid
        port = nil
        10.times do
            port = available_port

            read, write = IO.pipe

            # Really, really awkward code but we need a pipe to a PhantomJS
            # process which will ignore signals. So, we need a child-container
            # process to trap signals and ignore them and a IO.popen'ed
            # PhantomJS grand-child.
            phantomjs_container = fork do
                %w(QUIT INT).each do |signal|
                    next if !Signal.list.has_key?( signal )
                    trap( signal, 'IGNORE' )
                end

                write.sync = true

                io = IO.popen([ 'phantomjs',
                    "--webdriver=#{port}",
                    "--proxy=http://#{@proxy.address}/",
                    '--ignore-ssl-errors=true',
                    err: [:child, :out]]
                )
                phantomjs_pid = io.pid
                Process.detach io.pid

                # Send the PID to the parent right away, he may need to kill
                # PhantomJS if initialization takes too long.
                write.puts io.pid.to_s

                # Wait for PhantomJS to initialize.
                buff = ''
                while buff << io.gets.to_s
                    break if buff.include? 'running on port'
                end

                # All done, we're good to go.
                write.puts 'ping'

                # This is our lifeline to the parent. It will Kill the browser
                # if the parent dies for whatever reason.
                while sleep 0.1
                    begin
                        Process.kill 0, ppid
                    rescue Errno::ESRCH
                        Process.kill( 'KILL', phantomjs_pid ) rescue Errno::ESRCH
                        break
                    end
                end
            end
            Process.detach phantomjs_container

            # First read is the pid.
            @phantomjs_pid = read.readline.to_i

            # Wait for the container to let us know when PhantomJS is up and
            # running. If it doesn't make contact in time cleanup and start over.
            if !IO.select( [read], nil, nil, PHANTOMJS_SPAWN_TIMEOUT )
                read.close
                write.close

                kill_phantomjs
                next
            end

            read.close
            write.close

            break
        end

        @phantomjs_url = "http://localhost:#{port}"
    end

    def kill_phantomjs
        kill @phantomjs_pid

        @phantomjs_pid = nil
        @phantomjs_url = nil
    end

    def kill( pid )
        while sleep 0.1
            begin
                Process.kill( 'KILL', pid )
            rescue Errno::ESRCH
                break
            end
        end
    end

    def store_pages?
        !!@options[:store_pages]
    end

    def call_on_new_page_blocks( page )
        @on_new_page_blocks.each { |b| b.call page }
    end

    def call_on_new_page_with_sink_blocks( page )
        @on_new_page_with_sink_blocks.each { |b| b.call page }
    end

    def call_on_response_blocks( page )
        @on_response_blocks.each { |b| b.call page }
    end

    def call_on_fire_event_blocks( element, event )
        @on_fire_event_blocks.each { |b| b.call element, event }
    end

    # Loads `page` without taking a snapshot, used for restoring  the root page
    # after manipulation.
    def restore( page )
        load page, take_snapshot: false
    end

    def capture_snapshot_with_sink( page )
        return if page.dom.data_flow_sink.empty? &&
            page.dom.execution_flow_sink.empty?

        call_on_new_page_with_sink_blocks( page )

        return if !store_pages?
        @page_snapshots_with_sinks << page
    end

    def wait_for_pending_requests
        # With AJAX requests being asynchronous and everything we need
        # to wait a split second to give the browser time to initialize
        # a connection.
        #
        # TODO: Add XMLHttpRequest.send() overrides to the DOMMonitor so
        # that we'll know for sure when to wait.
        sleep 0.1

        # Wait for pending requests to complete.
        with_timeout Options.http.request_timeout do
            sleep 0.1 while @proxy.has_connections?
        end

        true
    rescue Timeout::Error
        #ap 'PENDING REQUESTS TIMEOUT'
        #ap caller
        false
    end

    def load_cookies( url, cookies = {} )
        # First clears the browser's cookies and then tricks it into accepting
        # the system cookies for its cookie-jar.

        url = normalize_url( url )
        watir.cookies.clear

        set_cookies = {}
        HTTP::Client.cookie_jar.for_url( url ).each do |cookie|
            set_cookies[cookie.name] = cookie
        end
        cookies.each do |cookie|
            set_cookies[cookie.name] = cookie
        end

        url = "#{url}/set-cookies-#{request_token}"
        watir.goto preload( HTTP::Response.new(
            url:     url,
            headers: {
                'Set-Cookie' => set_cookies.values.map(&:to_set_cookie)
            }
        ))
    end

    # Makes sure we have at least 2 windows open so that we can switch to the
    # last available one in case there's some JS in the page that closes one.
    def ensure_open_window
        return if watir.windows.size > 1

        watir.windows.last.use
        watir.window.resize_to( 1600, 1200 )

        @javascript.run( 'window.open()' )
    end

    # PhantomJS driver, the default.
    def phantomjs
        [selenium]
    end

    # Firefox driver, only used for debugging.
    def firefox
        profile = Selenium::WebDriver::Firefox::Profile.new
        profile.proxy = Selenium::WebDriver::Proxy.new http: @proxy.address,
                                                       ssl: @proxy.address
        [:firefox, profile: profile]
    end

    # Chrome driver, only used for debugging.
    def chrome
        [ :chrome, switches: [ "--proxy-server=#{@proxy.address}" ] ]
    end

    def capabilities
        Selenium::WebDriver::Remote::Capabilities.phantomjs(
            'phantomjs.page.settings.userAgent'  => Options.http.user_agent,
            'phantomjs.page.customHeaders.X-Arachni-Browser-Auth' => auth_token,
            'phantomjs.page.settings.resourceTimeout' => Options.http.request_timeout,
            'phantomjs.page.settings.loadImages' => !Options.browser_cluster.ignore_images
        )
    end

    def flush_request_transitions
        @request_transitions.dup
    ensure
        @request_transitions.clear
    end

    def request_token
        @request_token ||= generate_token
    end

    def auth_token
        @auth_token ||= generate_token.to_s
    end

    def request_handler( request, response )
        return if request.headers['X-Arachni-Browser-Auth'] != auth_token
        request.headers.delete( 'X-Arachni-Browser-Auth' )

        return if @javascript.serve( request, response )

        if !request.url.include?( request_token )
            return if ignore_request?( request )

            if @add_request_transitions
                @request_transitions << Page::DOM::Transition.new( request.url, :request )
            end
        end

        # Signal the proxy to not actually perform the request if we have a
        # preloaded or cached response for it.
        return if from_preloads( request, response ) || from_cache( request, response )

        # Capture the request as elements of pages -- let's us grab AJAX and
        # other browser requests and convert them into elements we can analyze
        # and audit.
        capture( request )

        request.headers['user-agent'] = Options.http.user_agent

        # Signal the proxy to continue with its request to the origin server.
        true
    end

    def response_handler( request, response )
        return if request.url.include?( request_token )

        @request_transitions.each do |transition|
            next if !transition.running? || transition.element != request.url
            transition.complete
        end

        return if skip_path?( response.url )

        intercept response
        save_response response
    end

    def intercept( response )
        return if !intercept?( response )
        @javascript.inject( response )
    end

    def intercept?( response )
        return false if response.body.empty?
        return false if !response.headers.content_type.to_s.start_with?( 'text/html' )

        body = response.body.downcase
        HTML_IDENTIFIERS.each { |tag| return true if body.include? tag.downcase }

        false
    end

    def ignore_request?( request )
        # Only allow CSS and JS resources to be loaded from out-of-scope domains.
        !['css', 'js'].include?( request.parsed_url.resource_extension ) &&
            skip_path?( request.url ) || Options.scope.redundant?( request.url ) ||
            Options.scope.auto_redundant_path?( request.url )
    end

    def capture( request )
        return if !@last_url || !capture?

        case request.method
            when :get
                inputs = parse_url_vars( request.url )
                return if inputs.empty?

                # Make this a Link.
                 form = Form.new(
                    url:    @last_url,
                    action: request.url,
                    method: request.method,
                    inputs: inputs
                )

            when :post
                inputs = form_parse_request_body( request.body )
                return if inputs.empty?

                form = Form.new(
                    url:    @last_url,
                    action: request.url,
                    method: request.method,
                    inputs: inputs
                )

            else
                return
        end

        # Don't bother is we or the system in general has already seen the vector.
        return if skip_state?( form.id ) || ElementFilter.include?( form )
        skip_state form.id

        page = Page.from_data( url: request.url, forms: [form] )
        page.response.request = request
        page.dom.push_transition Page::DOM::Transition.new( request.url, :request )

        @captured_pages << page if store_pages?
        call_on_new_page_blocks( page )
    end

    def from_preloads( request, response )
        return if !(preloaded = preloads.delete( request.url ))

        copy_response_data( preloaded, response )
        response.request = request
        save_response( response ) if !preloaded.url.include?( request_token )

        preloaded
    end

    def from_cache( request, response )
        return if !@cache.include?( request.url )

        copy_response_data( @cache[request.url], response )
        response.request = request
        save_response response
    end

    def copy_response_data( source, destination )
        [:code, :url, :body, :headers, :ip_address, :return_code,
         :return_message, :headers_string, :total_time, :time,
         :version].each do |m|
            destination.send "#{m}=", source.send( m )
        end

        intercept destination
        nil
    end

    def clear_responses
        synchronize { @window_responses.clear }
    end

    def save_response( response )
        call_on_response_blocks response
        return response if !response.text?
        @window_responses[response.url] = response
    end

    def get_response( url )
        synchronize { @window_responses[url] }
    end

    def synchronize( &block )
        @mutex.synchronize( &block )
    end

end
end

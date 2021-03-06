require 'rack'
require 'wiki/utils'

module Wiki
  module Routing
    class Request < Rack::Request
      def params
        self.GET.update(self.POST)
      rescue EOFError => ex
        self.GET
      end
    end

    class NotFound < NameError
      def status; 404 end
    end

    def self.included(base)
      base.extend(ClassMethods)
      base.class_eval do
        include Hooks
        include InstanceMethods
      end
    end

    module InstanceMethods
      attr_reader :params, :response, :request, :env

      def call(env)
        dup.call!(env)
      end

      def call!(env)
        @env      = env
        @request  = Request.new(env)
        @response = Rack::Response.new
        @params = @original_params = @request.params.indifferent
        catch(:forward) do
          perform!
          status, header, body = @response.finish
          return [status, header, @request.head? ? [] : body]
        end
        @app ? @app.call(env) : handle_error(NotFound.new('Sub application not set'))
      end

      def halt(*response)
        response = response.first if response.length == 1
        throw :halt, response
      end

      def redirect(uri); throw :redirect, uri end
      def pass; throw :pass end
      def forward; throw :forward end

      private

      def handle_error(ex)
        @response.status = ex.respond_to?(:status) ? ex.status : 500
        @response.body   = [ex.message]
        content_hook(ex.class, ex)
      end

      def perform!
        result = catch(:halt) do
          uri = catch(:redirect) do
            halt(dispatch!)
          end
          @response.status = 302
          @response['Location'] = uri
          nil
        end

        return if !result
        if result.respond_to?(:to_str)
          @response.body = [result]
        elsif result.respond_to?(:to_ary)
          result = result.to_ary
          if Fixnum === result.first
            if result.length == 3
              @response.status, headers, body = result
              @response.body = body if body
              @response.headers.merge!(headers) if headers
            elsif result.length == 2
              @response.status = result.first
              @response.body   = result.last
            else
              raise TypeError, "#{result.inspect} not supported"
            end
          else
            @response.body = result
          end
        elsif result.respond_to?(:each)
          @response.body = result
        elsif (100...599) === result
          @response.status = result
        end
      end

      def dispatch!
        route!
      rescue ::Exception => ex
        handle_error(ex)
      end

      def route!
        invoke_hook(:before_routing)

        path = unescape(@request.path_info)
        routes = self.class.routes[@request.request_method].to_a
        routes.each do |name, pattern, keys, method|
          if match = pattern.match(path)
            values = match.captures.to_a
            params =
              if keys.any?
                keys.zip(values).inject({}) do |hash,(k,v)|
                  hash[k] = v
                  hash
                end
              elsif values.any?
                {'captures' => values}
              else
                {}
              end
            @params = @original_params.merge(params)
            catch(:pass) do
              result = method.arity == 0 ? method.bind(self).call : method.bind(self).call(*values)
              halt(result)
            end
          end
        end

        raise NotFound, "Path #{path} not found"
      end

      private

      # Stolen from rack
      def unescape(s)
        s.gsub(/((?:%[0-9a-fA-F]{2})+)/n){
          [$1.delete('%')].pack('H*')
        }
      end

    end

    module ClassMethods
      attr_reader_with_default :routes => {}

      def patterns(patterns = nil)
        return (@patterns || {}) if !patterns
        (@patterns ||= {}).merge!(patterns)
      end

      def get(*paths, &block)
        add_route 'GET', paths, &block
        add_route 'HEAD', paths, &block
      end

      def put(*paths, &block);    add_route 'PUT',    paths, &block end
      def post(*paths, &block);   add_route 'POST',   paths, &block end
      def delete(*paths, &block); add_route 'DELETE', paths, &block end
      def head(*paths, &block);   add_route 'HEAD',   paths, &block end

      def dump_routes
        s = "=== ROUTES ===\n"
        routes.each do |method,routes|
          s << "  #{method}:\n"
          routes.each {|x| s << "    #{x[0]} -> #{x[1].source}\n" }
        end
        s
      end

      private

      def compile_route(path, patterns)
        keys = []
        if path.respond_to? :to_str
          pattern =
            Regexp.escape(path).gsub(/:(\w+)|\\\?/) do |match|
            case match
            when '\?'
              '?'
            else
              keys << $1
              patterns.key?($1.to_sym) ? "(#{patterns[$1.to_sym]})" : "([^/?&#\.]+)"
            end
          end
          [path, /^#{pattern}$/, keys]
        elsif path.respond_to? :match
          [path.source, path, keys]
        else
          raise TypeError, path
        end
      end

      def add_route(method, paths, opts={}, &block)
        opts = paths.last.is_a?(Hash) ? paths.pop : {}
        paths.each do |path|
          patterns = opts[:patterns] ? self.patterns.merge(opts[:patterns]) : self.patterns
          path, pattern, keys = compile_route(path, patterns)
          define_method "#{method} #{path}", &block
          routes[method] ||= []
          (routes[method] << [path, pattern, keys, instance_method("#{method} #{path}")]).last
        end
      end

    end
  end
end

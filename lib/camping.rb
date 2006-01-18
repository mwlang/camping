%w[rubygems active_record markaby metaid ostruct].each { |lib| require lib }

module Camping
  module Models; end ; module Views; end ; Models::Base = ActiveRecord::Base
  Markaby::Builder.class_eval { include Views }

  module Controllers
    module RM
      attr_accessor :input, :cookies, :headers, :body, :status
      def method_missing(m, *args, &blk)
        str = eval("markaby.#{m}(*args, &blk)")
        str = markaview(:layout) { str } rescue nil
        r(200, str.to_s, 'Content-Type' => 'text/html')
      end
      def render(m)
        str = markaview(m)
        str = markaview(:layout) { str } rescue nil
        r(200, str, "Content-Type" => 'text/html')
      end
      def redirect(*args)
        c, *args = args
        if c.respond_to? :urls
          c = c.urls.first 
          c.gsub!(/\(.+?\)/) do
            ((a = args.shift).respond_to?(:primary_key) ? a.method(a.primary_key) : a).to_s
          end
        end
        r(302, '', 'Location' => c)
      end
      def r(s, b, h = {}); @status = s; @headers.merge!(h); @body = b; end
      def service(e, m, a)
        @status, @headers = 200, {'Content-Type' => 'text/html'}
        @cookies = Camping.cookie_parse(e['HTTP_COOKIE'] || e['COOKIE'])
        cook = @cookies.marshal_dump.dup
        if ("POST" == e['REQUEST_METHOD']) and
            %r|\Amultipart/form-data.*boundary=\"?([^\";,]+)\"?|n.match(e['CONTENT_TYPE'])
          return r(500, "Urgh, multipart/form-data not yet supported.")
        else
          @input = Camping.qs_parse(e['REQUEST_METHOD'] == "POST" ? 
                                    $stdin.read(e['CONTENT_LENGTH'].to_i) : e['QUERY_STRING'])
        end

        @body = method( m.downcase ).call(*a)
        @headers['Set-Cookie'] = @cookies.marshal_dump.map { |k,v| "#{k}=#{Camping.escape(v)}; path=/" if v != cook[k] }.compact
        self
      end
      def to_s
        "Status: #{@status}\n#{@headers.map{|k,v|v.to_a.map{|v2|"#{k}: #{v2}"}}.flatten.join("\n")}\n\n#{@body}"
      end
      private
      def markaby
        Markaby::Builder.new( instance_variables.map { |iv| 
            [iv[1..-1].intern, instance_variable_get(iv)] }, {} )
      end
      def markaview(m, *args, &blk)
        markaby.instance_eval { Views.instance_method(m).bind(self).call(*args, &blk); self }.to_s
      end
    end
    class R; include RM end
    class NotFound < R; def get; r(404, h1('Camping Problem!') + h2('Not Found')); end end

    class << self
      def R(*urls); Class.new(R) { meta_def(:inherited) { |c| c.meta_def(:urls) { urls } } }; end
      def D(path)
        constants.each do |c| 
            k = const_get(c)
            return k, $~[1..-1] if (k.urls rescue "/#{c.downcase}").find { |x| path =~ /^#{x}\/?$/ }
        end
        [NotFound, []]
      end
    end
  end

  class Response; include Controllers::RM
    def initialize(s = 200, &blk)
      @headers, @body, @status = {}, "", s
      instance_eval &blk
    end
  end

  class << self
    def escape(s); s.to_s.gsub(/([^ a-zA-Z0-9_.-]+)/n){'%'+$1.unpack('H2'*$1.size).join('%').upcase}.tr(' ', '+') end
    def unescape(s); s.tr('+', ' ').gsub(/((?:%[0-9a-fA-F]{2})+)/n){[$1.delete('%')].pack('H*')} end
    def qs_parse(qs, d = '&;'); OpenStruct.new((qs||'').split(/[#{d}] */n).
        inject({}){|hsh, p|k, v = p.split('=',2).map {|v| unescape(v)}; hsh[k] = v unless v.empty?; hsh}) end
    def cookie_parse(s); c = qs_parse(s, ';,'); end
    def run
      begin
        k, a, m = Controllers.D(ENV['PATH_INFO']) + [ENV['REQUEST_METHOD'] || "GET"]
        k.class_eval { include Controllers::RM }
        o = k.new
        o.class.class_eval do
          Models.constants.each do |c|
            g = Models.const_get(c)
            remove_const c if const_defined? c
            const_set c, g
          end
        end
        puts o.service(ENV, m, a)
      rescue => e
        puts Response.new(200) { @headers['Content-Type'] = 'text/html'; @body = Markaby::Builder.new({}, {}) { h1 'Camping Problem!'; h2 "#{k}.#{m}"; h3 "#{e.class} #{e.message}:"; ul { e.backtrace.each { |bt| li bt } } }.to_s }
      end
    end
  end
end
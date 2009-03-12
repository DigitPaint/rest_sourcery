module RestSourcery
  module Resource    
    
    def self.included(base)
      base.send(:attr_accessor, :url)
      base.send(:attr_reader, :attributes, :errors)
      base.send(:mattr_inheritable, :scope, :associations)
      
      # This has to be done like this otherwise we have ruby
      # method calling problems.
      class << base
        attr_writer :collection_name, :resource_name, :current_scope
      end
    
      base.extend(ClassMethods)
      base.send(:include, InstanceMethods)
    end
    
    module ClassMethods
      
      def api_key=(key)
        self.headers.update("x-api-key" => key)
      end
  
      def collection_name(name=nil)
        @collection_name = name if name
        @collection_name || self.to_s.demodulize.underscore.pluralize
      end

      def resource_name(name=nil)
        @resource_name = name if name
        @resource_name || self.to_s.demodulize.underscore
      end
      
      def current_scope
        @current_scope || {}
      end
      
  
      # Define properties on the class
      # It's basically an accessor for the attributes hash.
      def property(*names)
        names.each do |name|
          define_method(name) do
            self.attributes[name.to_s]
          end
          define_method("#{name}=") do |v|
            self.attributes[name.to_s] = v
          end
        end
      end
  
      # Defines a has_many relationship between this class and another one
      #
      # ==== Parameters
      # collection_name<Symbol,String>:: The name of the collection (also defines the accessor method names)
      # options<Hash>:: Options, see below
      # 
      # ==== Options
      # :klass<Class>:: The class that will be used for the elements of this collection
      # :collection_url<String>:: The URL where we can get these elements ,defaults to the parent_url + the collection_name
      # --
      def has_many(collection_name,options={})
        class_name = (options[:klass] || collection_name.to_s.singularize.classify).to_s
        parent_url = options[:collection_url] && "\"#{options[:collection_url]}\"" || "self.class.build_url(self.url,\"#{collection_name}\")"
    
        # Register association
        self.associations ||= []
        self.associations << collection_name if !self.associations.include?(collection_name)
    
        # Define methods
        methods = <<-EOS
          def #{collection_name} 
            @#{collection_name} ||= ResourceCollectionProxy.new(#{parent_url},#{class_name})      
          end
      
          def #{collection_name}=(v)
            self.#{collection_name}.load(v)
          end
        EOS
        self.class_eval(methods,__FILE__,__LINE__)
      end
  

      # Build a new object with the right collection_url set
      #
      # ==== Parameters
      # attributes<Hash>:: The attributes hash
      # 
      # ==== Returns
      # EntopicMail:: A subclass of entopicmail
      # --
      def build(attributes)
        o = self.new(attributes)
        o.collection_url = self.collection_url
        o
      end

      # GET an object by id.
      #
      # ==== Parameters
      # id<~to_s>:: The ID of the object to GET
      # options<Hash>:: Hash
      #
      # ==== Options
      # :from<String> :: The collection url we should get the resource from, if empty it will try to determine the URL itself.
      #
      # --
      def find(id,options={})
        options.reverse_merge! :from => collection_url
        url = build_url(options[:from],id)
        if result = handle_response(self.get(url),url)
          e = self.new(result)
          e.url = url
          e
        end
      end
  
      # GET the whole collection
      #
      # ==== Parameters
      # options<Hash>:: Options Hash
      #
      # ==== Options
      # :from<String>:: The collection url we should get the resource from, if empty it will try to determine the URL itself.
      # :query<Hash>:: Query parameters to pass to the GET request
      # 
      # --
      def all(options={})
        options.reverse_merge! :from => collection_url, :query => {}
        request_options = options.slice(:query)
    
        url = build_url(options[:from])
        result = handle_response(self.get(url,request_options),url)
        if result && result.has_key?(self.collection_name)
          initialize_collection(result[self.collection_name],url)
        end
      end
  
      
      def build_url(*parts)
        ("/" + (parts.flatten * "/")).gsub("//","/")
      end
      
      def collection_url
        self.current_scope[:collection_url] || build_url(self.collection_name)
      end
    
      # Define a scope to use when doing HTTP requests
      #
      # ===== Params
      # options<Hash>:: The options hash
      #
      # ===== Options
      # :collection_url:: The URL where the collection of this object_type can be found
      #
      def with_scope(options,&block)
        self.scope ||= []
        self.scope << (self.current_scope || {}).merge(options)
        self.current_scope = self.scope.last
        yield
      ensure
        self.current_scope = self.scope.pop
      end
  
      protected
  
      def handle_response(response,url)
        case response.code
          when "200" then response
          when "404" then nil
          else raise("Invalid response: #{response.code} for #{url}")
        end
      end
  
      def initialize_collection(collection_data,url=nil)
        collection_data.map do |c| 
          o = self.new({self.resource_name => c})
          o.collection_url = url
          o
        end      
      end
    end # KlassMethods
    
    module InstanceMethods
      def initialize(params)
        load(params)
        @errors = {}
      end

      def load(params)
        if params.has_key?(self.resource_name)
          self.attributes = params[self.resource_name]
        else
          self.attributes = params
        end
      end

      def url=(v)
        @new_record = false
        @url = v
      end  

      def collection_url=(v)
        @collection_url = v
      end

      def collection_url
        @collection_url || self.class.collection_url
      end

      def attributes=(attributes)
        @attributes ||= {}
        attributes.each do |k,v|
          if self.respond_to?("#{k}=")
            self.send("#{k}=",v)
          else
            @attributes[k] = v
          end
        end
      end

      # Save this resource
      #
      # --
      def save(options={})  
        if self.new?
          response = self.create(options)
        else
          response = self.update(options)
        end
  
        case response.code
          when "201" then self.load(response) && true # Created
          when "200" then self.load(response) && true # Updated
          when "422" then handle_invalid(response)
          when "500" then raise("Failed with application error (500)")
          else raise("Invalid response: #{response.code}")
        end
  
      end

      def handle_invalid(response)
        self.load(response)
        if errors = @attributes.delete("errors")
          @errors = errors
        end    
        false
      end

      def create(options={})
        options.reverse_merge! :on => self.collection_url
        self.class.post(options[:on],:body => self.to_xml, :headers => {"content-type" => "application/xml"})    
      end

      def update(options={})
        options.reverse_merge! :on => self.url    
        self.class.put(options[:on],:body => self.to_xml, :headers => {"content-type" => "application/xml"})    
      end

      def resource_name
        self.class.resource_name
      end

      def to_xml(options={})
        attrs = {}
        self.attributes.each do |k,v|
          attrs[k] = self.respond_to?(k) ? self.send(k) : v
        end
  
        attrs.to_xml(options.merge(:root => self.resource_name)) do |builder|
          if self.class.associations
            self.class.associations.each do |assoc_name|
              collection_proxy = self.send(assoc_name)
              if collection_proxy.included?
                collection_proxy.to_xml(:builder => builder, :root => assoc_name.to_s, :skip_instruct => true)
              end
            end
          end
        end
      end

      def new?
        @new_record.nil? && true || @new_record
      end

      def id; self.attributes["id"]; end

      def method_missing(meth,*args)
        if meth.to_s =~ /=$/
          self.attributes[meth.to_s] = args.first
        elsif self.attributes.has_key?(meth.to_s)
          self.attributes[meth.to_s]
        else
          super
        end
      end
    end # InstanceMethods
  end # Resource
end # RestSourcery
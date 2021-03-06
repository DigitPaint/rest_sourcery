module RestSourcery
  module Resource    
    
    def self.included(base)
      base.send(:include, HTTParty)
      base.send(:attr_reader, :url, :attributes, :errors, :response)
      base.send(:mattr_inheritable, :scope, :associations, :property_map)
      base.instance_variable_set("@property_map", {})
      base.instance_variable_set("@associations", {})
      base.instance_variable_set("@scope", [])
      
      # This has to be done like this otherwise we have ruby
      # method calling problems.
      class << base
        attr_writer :collection_name, :resource_name, :current_scope
        alias :property_map_without_default :property_map
        alias :property_map_without_default= :property_map=
        def property_map
          self.property_map_without_default ||= {}
        end

        # Hack so we can still use subclassing with a base class.
        alias :inherited_with_clone :inherited        
        def inherited(subclass)
          self.inherited_with_clone(subclass)
          subclass.instance_variable_set("@default_options", self.instance_variable_get("@default_options"))
        end
        
      end
    
      base.extend(ClassMethods)
      base.send(:include, InstanceMethods)
    end
    
    module ClassMethods
        
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
      # It can also map accessors to other elements.
      def property(*names)
        protected_methods = %w{url attributes errors}
        
        names.each do |name|
          raise ArgumentError, "Can't define internal method #{name}, alias it as something else." if protected_methods.include?(name.to_s)
          
          if name.kind_of?(Hash)
            arr = name.to_a.first
            name = arr.first
            attribute = arr.last.to_s
          else
            attribute = name.to_s
          end
          self.property_map[attribute] = name          
          
          define_method(name) do
            self.attributes[attribute]
          end
          define_method("#{name}=") do |v|
            self.attributes[attribute] = v
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
      # :included<Boolean>:: Is this a nested collection? If it is it will always be included in the parent when storing
      # --
      def has_many(collection_name, options={})
        class_name = (options[:klass] || collection_name.to_s.singularize.classify).to_s
        proxy_options = options
    
        # Register association
        self.associations ||= {}
        self.associations[collection_name.to_s] = options if !self.associations.has_key?(collection_name)
    
        # Define methods
        methods = <<-EOS
          def #{collection_name}(options={}) 
            @#{collection_name} ||= ResourceCollectionProxy.new(self, #{class_name}, options, self.class.associations["#{collection_name}"])
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
      # :query<Hash>:: Query parameters to pass to the GET request
      # :headers<Hash>:: Headers to pass
      #
      # --
      def find(id,options={})
        options.reverse_merge! :from => collection_url
        request_options = options.slice(:query, :headers)
                
        url = build_url(options[:from],id)
        if result = handle_response(self.get(url, request_options),url)
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
        request_options = options.slice(:query, :headers)
    
        url = build_url(options[:from])
        result = handle_response(self.get(url, request_options),url)
        if result && result.has_key?(self.collection_name)
          initialize_collection(result[self.collection_name],url)
        end
      end
  
      
      def build_url(*parts)
        url = (parts.flatten.map{|c| c = c.to_s; c =~ /^\// ? c.split("/")[1..-1] : c.split("/") }.flatten * "/")
        url =~ /^http:\/\/|^\// ? url : "/" + url
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
        case response.code.to_s
          when "200" then response
          when "404" then nil
          else raise("Invalid response: #{response.code} for #{url}")
        end
      end
  
      # Initialize a collection that comes from remote
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
        self.attributes = {}        
        load(params)
        @errors = {}
      end

      # Load the resources data from a response, if the hash
      # has a key called like this resource (self.resource_name) it will only pass
      # that key to attributes=
      #
      # ==== Parameters
      # params<Hash>:: The data hash to load
      # --
      def load(params)
        return if params.blank?
        if params.has_key?(self.resource_name)
          self.attributes = params[self.resource_name]
        else
          self.attributes = params
        end
      end

      # Set the URL of this resource if this URL is set
      # RestSourcery considers this resource an existing one (not new)
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
            @attributes[k.to_s] = v
          end
        end
      end

      # Save this resource
      #
      # ==== Options
      # :on:: The url to save this resource to
      # :headers:: The extra headers to set for this request
      #
      # ==== Returns
      # true:: If the resource has been saved
      # false:: The resource could not be saved, tries to set self.errors 
      # --
      def save(options={})
        return false if !handle_callback(:before_save)
        
        if self.new?
          return false if !handle_callback(:before_create)
          response = self.create(options)
        else
          return false if !handle_callback(:before_update)
          response = self.update(options)
        end
  
        case response.code.to_s
          when "201","200" then handle_valid_response(response)
          when "422", "432" then handle_invalid_response(response)
          when "401" then raise("Unauthorized access (401)")
          when "500"
            if response.body.include?("DMQ::ConnectFailedError")
              raise("Failed Connect to DMQ (500)")
            else
              raise("Failed with application error (500)")
            end
          else raise("Invalid response: #{response.code}")
        end
  
      end

      def create(options={})
        options.reverse_merge! :on => self.collection_url
        req = {:body => self.to_xml} 
        req[:headers] = options[:headers] if options[:headers]
        self.class.post(options[:on], req)
      end

      def update(options={})
        options.reverse_merge! :on => self.url    
        req = {:body => self.to_xml} 
        req[:headers] = options[:headers] if options[:headers]        
        self.class.put(options[:on], req)
      end

      # Destroy this resource
      #
      # ==== Options
      # :on:: The url to destroy this resource at
      #
      # ==== Returns
      # true:: The resource has been destroyed
      # false:: The resource could not be destroyed (check if this isn't a new record!)
      # --
      def destroy(options={})
        return false if self.new?
        options.reverse_merge! :on => self.url
        response = self.class.delete(options[:on])
        case response.code.to_s
          when "200" then self.freeze && true
          when "500"
            if response.body.include?("DMQ::ConnectFailedError")
              raise("Failed Connect to DMQ (500)")
            else
              raise("Failed with application error (500)")
            end
          else false
        end
      end


      def resource_name
        self.class.resource_name
      end

      # Serialize this resource
      #
      # ==== Parameters
      # options<Hash>:: Options to pass to the attributes.to_xml method
      #
      # ==== Options
      # These are additional options to this method which will NOT be passed to Hash.to_xml
      # :except<String,Array>:: An array or just a single key of the attributes hash that will not be passed to to_xml
      #
      # ==== Returns
      # String:: This object serialized as XML
      # --
      def to_xml(options={})
        attrs = {}
        except_attrs = options.delete(:except) || []
        except_attrs = [except_attrs] unless except_attrs.kind_of?(Array)
        except_attrs.map!{|a| a.to_s }
        
        # Collect all properties in the property_map
        self.class.property_map.each do |attr_k,model_k|
          next if except_attrs.include?(attr_k) || except_attrs.include?(model_k)
          if self.respond_to?(model_k)
            attrs[attr_k] =  self.send(model_k)
          end
        end
        
        # Collect all attributes, don't take those we have already matched in the propertymap
        self.attributes.each do |k,v|
          next if attrs.has_key?(k) || except_attrs.include?(k)
          attrs[k] = self.respond_to?(k) ? self.send(k) : v
        end
        
  
        attrs.to_xml(options.merge(:root => self.resource_name)) do |builder|
          yield(builder) if block_given?
          if self.class.associations
            self.class.associations.each do |assoc_name,options|
              next if except_attrs.include?(assoc_name)
              collection_proxy = self.send(assoc_name)
              if collection_proxy.included? && collection_proxy.size > 0
                collection_proxy.to_xml(:builder => builder, :root => assoc_name.to_s, :skip_instruct => true)
              end
            end
          end
        end
      end

      # Is this a new record?
      def new?
        @new_record.nil? && true || @new_record
      end

      # We have to force this one as it won't work with method_missing
      def id; self.attributes["id"]; end
      def type; self.attributes["type"]; end

      # Dynamic attributes hash accessors
      def method_missing(meth,*args)
        if meth.to_s =~ /=$/
          self.attributes[meth.to_s.gsub(/=$/,'')] = args.first
        elsif self.attributes.has_key?(meth.to_s)
          self.attributes[meth.to_s]
        else
          super
        end
      end
      
      protected
      
      def handle_callback(callback_name)
        return true unless self.respond_to? callback_name
        
        !(self.send(callback_name) == false)
      end
      
      def handle_invalid_response(response)
        @response = response
        self.load(response)
        if errors = @attributes.delete("errors")
          @errors = errors
        end
        false
      end
      
      def handle_valid_response(response)
        self.load(response)
        if response.headers.has_key?("location")
          self.url = response.headers["location"].to_s
        end
        true
      end
      
    end # InstanceMethods
  end # Resource
end # RestSourcery
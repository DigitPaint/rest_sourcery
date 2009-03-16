module RestSourcery
  class ResourceCollectionProxy
  
    attr_reader :owner, :klass, :options
  
    # Constructor
    #
    # ==== Parameters
    # owner<Resource>:: The owner object
    # klass<Class>:: The class of the associated objects
    # 
    # ==== Options
    # on<String>:: The collection URL this colleciton can be found
    # --
    def initialize(owner,klass,options)
      @options = options
      @owner = owner
      @klass = klass
    end
  
    # Has this collection been included as a child of another collection
    # or does it know what to do with itself?
    def included?
      @_included
    end
    
    def collection_url
      self.options[:on] || self.owner.class.build_url(owner.url,klass.collection_name)
    end
  
    def build(attributes)
      @klass.with_scope(:collection_url => self.collection_url) do    
        obj = @klass.build(attributes)
        self << obj unless @collection.nil?
        obj
      end
    end
  
    def load(values)
      @collection = @klass.send(:initialize_collection,values)
      @_included = true
      self
    end
  
    def method_missing(meth,*args,&block)
      if @klass.respond_to?(meth)
        @klass.with_scope(:collection_url => self.collection_url) do
          @klass.send(meth,*args,&block)
        end
      else
        @collection = self.all if @collection.nil?
        if !@collection.nil? && @collection.respond_to?(meth)
          @collection.send(meth,*args,&block)
        else
          super
        end
      end
    end  
  end
end
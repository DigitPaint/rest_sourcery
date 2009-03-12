module RestSourcery
  class ResourceCollectionProxy
  
    def initialize(parent_url,klass)
      @parent_url = parent_url
      @klass = klass
    end
  
    # Has this collection been included as a child of another collection
    # or does it know what to do with itself?
    def included?
      @_included
    end
  
    def build(attributes)
      @klass.with_scope(:collection_url => @parent_url) do    
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
        @klass.with_scope(:collection_url => @parent_url) do
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
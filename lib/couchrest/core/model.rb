# = CouchRest::Model - ORM, the CouchDB way
module CouchRest
  # = CouchRest::Model - ORM, the CouchDB way
  #  
  # CouchRest::Model provides an ORM-like interface for CouchDB documents. It
  # avoids all usage of <tt>method_missing</tt>, and tries to strike a balance
  # between usability and magic. See CouchRest::Model#view_by for
  # documentation about the view-generation system.
  #  
  # ==== Example
  #  
  # This is an example class using CouchRest::Model. It is taken from the
  # spec/couchrest/core/model_spec.rb file, which may be even more up to date
  # than this example.
  #  
  #   class Article < CouchRest::Model
  #     use_database CouchRest.database!('http://localhost:5984/couchrest-model-test')
  #     unique_id :slug
  #
  #     view_by :date, :descending => true
  #     view_by :user_id, :date
  #
  #     view_by :tags,
  #       :map => 
  #         "function(doc) {
  #           if (doc['couchrest-type'] == 'Article' && doc.tags) {
  #             doc.tags.forEach(function(tag){
  #               emit(tag, 1);
  #             });
  #           }
  #         }",
  #       :reduce => 
  #         "function(keys, values, rereduce) {
  #           return sum(values);
  #         }"  
  #
  #     key_writer :date
  #     key_reader :slug, :created_at, :updated_at
  #     key_accessor :title, :tags
  #
  #     timestamps!
  #
  #     before(:create, :generate_slug_from_title)  
  #     def generate_slug_from_title
  #       self['slug'] = title.downcase.gsub(/[^a-z0-9]/,'-').squeeze('-').gsub(/^\-|\-$/,'')
  #     end
  #   end
  class Model < Hash

    # instantiates the hash by converting all the keys to strings.
    def initialize keys = {}
      super()
      apply_defaults
      keys.each do |k,v|
        self[k.to_s] = v
      end
      unless self['_id'] && self['_rev']
        self['couchrest-type'] = self.class.to_s
      end
    end

    class << self
      # this is the CouchRest::Database that model classes will use unless
      # they override it with <tt>use_database</tt>
      attr_accessor :default_database
      attr_accessor :template

      # override the CouchRest::Model-wide default_database
      def use_database db
        @database = db
      end

      # returns the CouchRest::Database instance that this class uses
      def database
        @database || CouchRest::Model.default_database
      end

      # load a document from the database
      def get id
        doc = database.get id
        new(doc)
      end

      def cast field, opts = {}
        @casts ||= {}
        @casts[field.to_s] = opts
      end

      # Defines methods for reading and writing from fields in the document.
      # Uses key_writer and key_reader internally.
      def key_accessor *keys
        key_writer *keys
        key_reader *keys
      end

      # For each argument key, define a method <tt>key=</tt> that sets the
      # corresponding field on the CouchDB document.
      def key_writer *keys
        keys.each do |method|
          key = method.to_s
          define_method "#{method}=" do |value|
            self[key] = value
          end
        end
      end

      # For each argument key, define a method <tt>key</tt> that reads the
      # corresponding field on the CouchDB document.      
      def key_reader *keys
        keys.each do |method|
          key = method.to_s
          define_method method do
            self[key]
          end
        end
      end

      def default
        @default
      end

      def set_default hash
        @default = hash
      end

      # Automatically set <tt>updated_at</tt> and <tt>created_at</tt> fields
      # on the document whenever saving occurs. CouchRest uses a pretty
      # decent time format by default. See Time#to_json
      def timestamps!
        before(:create) do
          self['updated_at'] = self['created_at'] = Time.now
        end                  
        before(:update) do   
          self['updated_at'] = Time.now
        end
      end

      # Name a method that will be called before the document is first saved,
      # which returns a string to be used for the document's <tt>_id</tt>.
      # Because CouchDB enforces a constraint that each id must be unique,
      # this can be used to enforce eg: uniq usernames. Note that this id
      # must be globally unique across all document types which share a
      # database, so if you'd like to scope uniqueness to this class, you
      # should use the class name as part of the unique id.
      def unique_id method = nil, &block
        if method
          define_method :set_unique_id do
            self['_id'] ||= self.send(method)
          end
        elsif block
          define_method :set_unique_id do
            uniqid = block.call(self)
            raise ArgumentError, "unique_id block must not return nil" if uniqid.nil?
            self['_id'] ||= uniqid
          end
        end
      end

      # Define a CouchDB view. The name of the view will be the concatenation
      # of <tt>by</tt> and the keys joined by <tt>_and_</tt>
      #  
      # ==== Example views:
      #  
      #   class Post
      #     # view with default options
      #     # query with Post.by_date
      #     view_by :date, :descending => true
      #  
      #     # view with compound sort-keys
      #     # query with Post.by_user_id_and_date
      #     view_by :user_id, :date
      #  
      #     # view with custom map/reduce functions
      #     # query with Post.by_tags :reduce => true
      #     view_by :tags,                                                
      #       :map =>                                                     
      #         "function(doc) {                                          
      #           if (doc['couchrest-type'] == 'Post' && doc.tags) {                   
      #             doc.tags.forEach(function(tag){                       
      #               emit(doc.tag, 1);                                   
      #             });                                                   
      #           }                                                       
      #         }",                                                       
      #       :reduce =>                                                  
      #         "function(keys, values, rereduce) {                       
      #           return sum(values);                                     
      #         }"                                                        
      #   end
      #  
      # <tt>view_by :date</tt> will create a view defined by this Javascript
      # function:
      #  
      #   function(doc) {
      #     if (doc['couchrest-type'] == 'Post' && doc.date) {
      #       emit(doc.date, null);
      #     }
      #   }
      #  
      # It can be queried by calling <tt>Post.by_date</tt> which accepts all
      # valid options for CouchRest::Database#view. In addition, calling with
      # the <tt>:raw => true</tt> option will return the view rows
      # themselves. By default <tt>Post.by_date</tt> will return the
      # documents included in the generated view.
      #  
      # CouchRest::Database#view options can be applied at view definition
      # time as defaults, and they will be curried and used at view query
      # time. Or they can be overridden at query time.
      #  
      # Custom views can be queried with <tt>:reduce => true</tt> to return
      # reduce results. The default for custom views is to query with
      # <tt>:reduce => false</tt>.
      #  
      # Views are generated (on a per-model basis) lazily on first-access.
      # This means that if you are deploying changes to a view, the views for
      # that model won't be available until generation is complete. This can
      # take some time with large databases. Strategies are in the works.
      #  
      # To understand the capabilities of this view system more compeletly,
      # it is recommended that you read the RSpec file at
      # <tt>spec/core/model.rb</tt>.
      def view_by *keys
        opts = keys.pop if keys.last.is_a?(Hash)
        opts ||= {}
        type = self.to_s

        method_name = "by_#{keys.join('_and_')}"
        @@design_doc ||= default_design_doc

        if opts[:map]
          view = {}
          view['map'] = opts.delete(:map)
          if opts[:reduce]
            view['reduce'] = opts.delete(:reduce)
            opts[:reduce] = false
          end
          @@design_doc['views'][method_name] = view
        else
          doc_keys = keys.collect{|k|"doc['#{k}']"}
          key_protection = doc_keys.join(' && ')
          key_emit = doc_keys.length == 1 ? "#{doc_keys.first}" : "[#{doc_keys.join(', ')}]"
          map_function = <<-JAVASCRIPT
          function(doc) {
            if (doc['couchrest-type'] == '#{type}' && #{key_protection}) {
              emit(#{key_emit}, null);
            }
          }
          JAVASCRIPT
          @@design_doc['views'][method_name] = {
            'map' => map_function
          }
        end

        @@design_doc_fresh = false

        self.meta_class.instance_eval do
          define_method method_name do |*args|
            query = opts.merge(args[0] || {})
            query[:raw] = true if query[:reduce]
            unless @@design_doc_fresh
              refresh_design_doc
            end
            raw = query.delete(:raw)
            view_name = "#{type}/#{method_name}"

            view = fetch_view(view_name, query)
            if raw
              view
            else
              # TODO this can be optimized once the include-docs patch is applied
              view['rows'].collect{|r|new(database.get(r['id']))}
            end
          end
        end
      end

      private

      def fetch_view view_name, opts
        retryable = true
        begin
          database.view(view_name, opts)
          # the design doc could have been deleted by a rouge process
        rescue RestClient::ResourceNotFound => e
          if retryable
            refresh_design_doc
            retryable = false
            retry
          else
            raise e
          end
        end
      end

      def design_doc_id
        "_design/#{self.to_s}"
      end

      def default_design_doc
        {
          "_id" => design_doc_id,
          "language" => "javascript",
          "views" => {}
        }
      end

      def refresh_design_doc
        saved = database.get(design_doc_id) rescue nil
        if saved
          @@design_doc['views'].each do |name, view|
            saved['views'][name] = view
          end
          database.save(saved)
        else
          database.save(@@design_doc)
        end
        @@design_doc_fresh = true
      end

    end # class << self



    # returns the database used by this model's class
    def database
      self.class.database
    end

    # alias for self['_id']
    def id
      self['_id']
    end

    # alias for self['_rev']      
    def rev
      self['_rev']
    end

    # returns true if the document has never been saved
    def new_record?
      !rev
    end

    # Saves the document to the db using create or update. Also runs the :save
    # callbacks. Sets the <tt>_id</tt> and <tt>_rev</tt> fields based on
    # CouchDB's response.
    def save
      if new_record?
        create
      else
        update
      end
    end

    # Deletes the document from the database. Runs the :delete callbacks.
    # Removes the <tt>_id</tt> and <tt>_rev</tt> fields, preparing the
    # document to be saved to a new <tt>_id</tt>.
    def destroy
      result = database.delete self
      if result['ok']
        self['_rev'] = nil
        self['_id'] = nil
      end
      result['ok']
    end

    protected

    # Saves a document for the first time, after running the before(:create)
    # callbacks, and applying the unique_id.
    def create
      set_unique_id if respond_to?(:set_unique_id) # hack
      save_doc
    end

    # Saves the document and runs the :update callbacks.
    def update
      save_doc
    end

    private

    def save_doc
      result = database.save self
      if result['ok']
        self['_id'] = result['id']
        self['_rev'] = result['rev']
      end
      result['ok']
    end

    def apply_defaults
      if self.class.default
        self.class.default.each do |k,v|
          self[k.to_s] = v
        end
      end
    end

    include ::Extlib::Hook
    register_instance_hooks :save, :create, :update, :destroy

  end # class Model
end # module CouchRest
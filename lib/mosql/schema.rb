module MoSQL
  class SchemaError < StandardError; end;

  class Schema
    include MoSQL::Logging

    def to_array(lst)
      lst.map do |ent|
        col = nil
        if ent.is_a?(Hash) && ent[:source].is_a?(String) && ent[:type].is_a?(String)
          # new configuration format
          col = {
            :source => ent.fetch(:source),
            :type   => ent.fetch(:type),
            :name   => (ent.keys - [:source, :type]).first,
          }
        elsif ent.is_a?(Hash) && ent.keys.length == 1 && ent.values.first.is_a?(String)
          col = {
            :source => ent.first.first,
            :name   => ent.first.first,
            :type   => ent.first.last
          }
        else
          raise SchemaError.new("Invalid ordered hash entry #{ent.inspect}")
        end

        if !col.key?(:array_type) && /\A(.+)\s+array\z/i.match(col[:type])
          col[:array_type] = $1
        end

        col
      end
    end

    def check_columns!(ns, spec)
      seen = Set.new
      spec[:columns].each do |col|
        if seen.include?(col[:source])
          raise SchemaError.new("Duplicate source #{col[:source]} in column definition #{col[:name]} for #{ns}.")
        end
        seen.add(col[:source])
      end
    end

    def parse_spec(ns, spec, related='')
      log.debug {"Parse spec, #{ns}, #{spec}, #{related}"}
      out = spec.dup
      out[:columns] = to_array(spec.fetch(:columns))
      check_columns!(ns, out)
      out[:meta] ||= {}
      if out[:meta][:created_at]
        out[:columns] << {
          :source => related.empty? ? '_id' : [related, '_id'].join('.'),
          :type   => 'TIMESTAMP',
          :name   => 'created_at',
          :key    => false
        }
      end
      if spec[:related]
        out[:related] = {}
        spec[:related].each do |reltable, details|
          log.debug {"Related schema, #{reltable}, #{details}"}
          table = reltable
          if is_embed_array = reltable.end_with?("[]")
            table = reltable.slice(0...-2)
          end
          out[:related][table] = parse_spec(
            [ns, table].join('.'), details, reltable)
          out[:related][table][:meta][:table] ||= table
          if is_embed_array
            out[:related][table][:meta][:embed_array] = true
          end
          out[:related][table][:columns] << {
            :source => '_id',
            :type   => 'VARCHAR(24)',
            :name   => ns.split('.')[-1].downcase+'_id',
          }
        end
      end
      log.debug {"Parsed spec, #{ns}, #{out}, #{spec}"}
      out
    end

    def parse_meta(meta)
      meta = {} if meta.nil?
      meta[:alias] = [] unless meta.key?(:alias)
      meta[:alias] = [meta[:alias]] unless meta[:alias].is_a?(Array)
      meta[:alias] = meta[:alias].map { |r| Regexp.new(r) }
      meta
    end

    def initialize(map)
      @map = {}
      map.each do |dbname, db|
        @map[dbname] = { :meta => parse_meta(db[:meta]) }
        db.each do |cname, spec|
          next unless cname.is_a?(String)
          begin
            @map[dbname][cname] = parse_spec("#{dbname}.#{cname}", spec)
          rescue KeyError => e
            raise SchemaError.new("In spec for #{dbname}.#{cname}: #{e}")
          end
        end
      end

      # Lurky way to force Sequel force all timestamps to use UTC.
      Sequel.default_timezone = :utc
    end

    def create_schema(db, clobber=false)
      @map.values.each do |dbspec|
        dbspec.each do |n, collection|
          next unless n.is_a?(String)
          meta = collection[:meta]
          composite_key = meta[:composite_key]
          keys = []
          log.info("Creating table '#{meta[:table]}'...")
          db.send(clobber ? :create_table! : :create_table?, meta[:table]) do
            collection[:columns].each do |col|
              opts = {}
              if col[:source] == '$timestamp'
                opts[:default] = Sequel.function(:now)
              end
              column col[:name], col[:type], opts

              if composite_key and composite_key.include?(col[:name])
                keys << col[:name].to_sym
              elsif not composite_key and col[:source].to_sym == :_id and col[:key] != false
                keys << col[:name].to_sym
              end
            end

            primary_key keys
            if meta[:extra_props]
              type =
                case meta[:extra_props]
                when 'JSON'
                  'JSON'
                when 'JSONB'
                  'JSONB'
                else
                  'TEXT'
                end
              column '_extra_props', type
            end
          end
          if collection[:related]
            collection[:related].each do |reltable, details|
              log.info("Creating related table '#{details[:meta][:table]}'...")
              db.send(clobber ? :create_table! : :create_table?, details[:meta][:table]) do
                details[:columns].each do |col|
                  column col[:name], col[:type]
                end
              end
            end
          end
        end
      end
    end

    def find_db(db)
      unless @map.key?(db)
        @map[db] = @map.values.find do |spec|
          spec && spec[:meta][:alias].any? { |a| a.match(db) }
        end
      end
      @map[db]
    end

    def find_ns(ns)
      db, collection, relation = ns.split(".")
      unless spec = find_db(db)
        return nil
      end
      unless schema = spec[collection]
        log.debug("No mapping for ns: #{ns}")
        return nil
      end
      if schema && relation
        schema = schema[:related][relation]
      end
      schema
    end

    def find_ns!(ns)
      schema = find_ns(ns)
      raise SchemaError.new("No mapping for namespace: #{ns}") if schema.nil?
      schema
    end

    def fetch_and_delete_dotted(obj, dotted)
      key, rest = dotted.split(".", 2)
      obj ||= {}

      if key.end_with?("[]")
        values = obj[key.slice(0...-2)] || []
        raise "Expected: Array for piece #{ key }, got #{ values.class }" unless values.is_a?(Array)

        return values.map do |v|
          if rest
            fetch_and_delete_dotted(v, rest)
          else
            v
          end
        end
      end

      # Base case
      return obj[key] unless rest

      fetch_and_delete_dotted(obj[key], rest)
    end

    def fetch_exists(obj, dotted)
      pieces = dotted.split(".")
      while pieces.length > 1
        key = pieces.shift
        obj = obj[key]
        return false unless obj.is_a?(Hash)
      end
      obj.has_key?(pieces.first)
    end

    def fetch_special_source(obj, source, original)
      case source
      when "$timestamp"
        Sequel.function(:now)
      when /^\$exists (.+)/
        # We need to look in the cloned original object, not in the version that
        # has had some fields deleted.
        fetch_exists(original, $1)
      else
        raise SchemaError.new("Unknown source: #{source}")
      end
    end

    def transform_primitive(v, type=nil)
      case v
      when BSON::ObjectId, Symbol
        if type and [:DATE, :TIMESTAMP, :TIME].include? type.to_sym
          Time.at(v.to_s[0...8].to_i(16)).utc
        else
          v.to_s
        end
      when BSON::Binary
        if type.downcase == 'uuid'
          v.to_s.unpack("H*").first
        else
          Sequel::SQL::Blob.new(v.to_s)
        end
      when BSON::DBRef
        v.object_id.to_s
      else
        v
      end
    end

    def transform(ns, obj, schema=nil)
      schema ||= find_ns!(ns)

      original = obj

      # Do a deep clone, because we're potentially going to be
      # mutating embedded objects.
      obj = BSON.deserialize(BSON.serialize(obj))

      row = []
      schema[:columns].each do |col|

        source = col[:source]
        type = col[:type]

        if source.start_with?("$")
          v = fetch_special_source(obj, source, original)
        else
          begin
            v = fetch_and_delete_dotted(obj, source)
          rescue
            log.warn("Trasnform failed, skipping: source=#{source}, data=#{obj}")
            return nil
          end
          case v
          when Hash
            v = JSON.dump(Hash[v.map { |k,v| [k, transform_primitive(v)] }])
          when Array
            v = v.map { |it| transform_primitive(it, type) }
            key, _ = source.split(".", 2)
            unless key.end_with?("[]")
              if col[:array_type]
                v = Sequel.pg_array(v, col[:array_type])
              else
                v = JSON.dump(v)
              end
            else
              v
            end
          else
            v = transform_primitive(v, type)
          end
        end
        row << v
      end

      if schema[:meta][:extra_props]
        extra = sanitize(obj)
        row << JSON.dump(extra)
      end

      log.debug { "Transformed: #{row.inspect}" }
      arrays = row.select {|r| r.is_a? Array}
      return row unless arrays.any?
      depth = arrays[0].length

      # Convert row [a, [b, c], d] into [[a, b, d], [a, c, d]]
      row.map! {|r| [r].flatten.cycle.take(depth)}
      row.first.zip(*row.drop(1))
    end

    def sanitize(value)
      # Base64-encode binary blobs from _extra_props -- they may
      # contain invalid UTF-8, which to_json will not properly encode.
      case value
      when Hash
        ret = {}
        value.each {|k, v| ret[k] = sanitize(v)}
        ret
      when Array
        value.map {|v| sanitize(v)}
      when BSON::Binary
        Base64.encode64(value.to_s)
      when Float
        # NaN is illegal in JSON. Translate into null.
        value.nan? ? nil : value
      else
        value
      end
    end

    def copy_column?(col)
      col[:source] != '$timestamp'
    end

    def all_columns(schema, copy=false)
      cols = []
      schema[:columns].each do |col|
        cols << col[:name] unless copy && !copy_column?(col)
      end
      if schema[:meta][:extra_props]
        cols << "_extra_props"
      end
      cols
    end

    def all_columns_for_copy(schema)
      all_columns(schema, true)
    end

    def copy_data(db, ns, objs)
      schema = find_ns!(ns)
      db.synchronize do |pg|
        sql = "COPY \"#{schema[:meta][:table]}\" " +
          "(#{all_columns_for_copy(schema).map {|c| "\"#{c}\""}.join(",")}) FROM STDIN"
        pg.execute(sql)
        objs.each do |o|
          pg.put_copy_data(transform_to_copy(ns, o, schema) + "\n")
        end
        pg.put_copy_end
        begin
          pg.get_result.check
        rescue PGError => e
          db.send(:raise_error, e)
        end
      end
    end

    def quote_copy(val)
      case val
      when nil
        "\\N"
      when true
        't'
      when false
        'f'
      when Sequel::SQL::Function
        nil
      when DateTime, Time
        val.strftime("%FT%T.%6N %z")
      when Sequel::SQL::Blob
        "\\\\x" + [val].pack("h*")
      else
        val.to_s.gsub(/([\\\t\n\r])/, '\\\\\\1')
      end
    end

    def transform_to_copy(ns, row, schema=nil)
      row.map { |c| quote_copy(c) }.compact.join("\t")
    end

    def table_for_ns(ns)
      find_ns!(ns)[:meta][:table]
    end

    def all_mongo_dbs
      @map.keys
    end

    def collections_for_mongo_db(db)
      (@map[db]||{}).keys
    end

    def primary_sql_key_for_ns(ns)
      ns = find_ns!(ns)
      keys = []
      if ns[:meta][:composite_key]
        keys = ns[:meta][:composite_key]
      else
        keys << ns[:columns].find {|c| c[:source] == '_id' && c[:key] != false }[:name]
      end

      return keys
    end
  end
end

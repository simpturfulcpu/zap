module Zap::Utils::Macros
  macro safe_getter(name, &block)
    @{{name.var.id}} : {{name.type}}?

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_{{name.var.id}}_lock = Mutex.new

    def {{name.var.id}} : {{name.type}}
      if (value = @{{name.var.id}}).nil?
        @{{name.var.id}} = @_{{name.var.id}}_lock.synchronize do
          {{ yield }}
        end
      else
        value
      end
    end
  end

  macro safe_property(name, &block)
    @{{name.var.id}} : {{name.type}}?

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @_{{name.var.id}}_lock = Mutex.new

    def {{name.var.id}} : {{name.type}}
      if (  value = @{{name.var.id}}).nil?
        @{{name.var.id}} = @_{{name.var.id}}_lock.synchronize do
          {{ yield }}
        end
      else
        value
      end
    end
    def {{name.var.id}}=({{name.var.id}} : {{name.type}})
      @{{name.var.id}} = {{name.var.id}}
    end
  end
end

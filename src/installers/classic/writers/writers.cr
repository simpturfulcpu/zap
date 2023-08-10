abstract struct Zap::Installer::Classic::Writer
  getter dependency : Package
  getter installer : Zap::Installer::Classic::Installer
  getter location : LocationNode
  getter state : Commands::Install::State
  getter ancestors : Array(Package)
  getter aliased_name : String?

  def initialize(
    @dependency : Package,
    *,
    @installer : Zap::Installer::Classic::Installer,
    @location : LocationNode,
    @state : Commands::Install::State,
    @ancestors : Array(Package),
    @aliased_name : String?
  )
  end

  alias InstallResult = {LocationNode?, Bool}

  abstract def install : InstallResult

  def self.init_location(dependency : Package, target_path : Path, location : LocationNode, aliased_name : String? = nil) : LocationNode
    LocationNode.new(
      node_modules: target_path / "node_modules",
      package: dependency,
      root: false,
      parent: location
    )
  end
end

require "./*"

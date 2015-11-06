require 'dinghy/constants'
require 'json'

class Machine
  class CommandFailed < RuntimeError
    attr_reader :exitstatus
    def initialize(message, exitstatus)
      super(message)
      @exitstatus = exitstatus
    end
  end

  def create(options = {})
    provider = options['provider']

    out, err = System.capture_output {
      system("create", "-d", provider, *CreateOptions.generate(provider, options), machine_name)
    }

    if System.command_failed?
      $stderr.puts err
      raise("There was an error creating the VM.")
    end

    configure_new_machine(provider)
  end

  def up
    out, err = System.capture_output {
      system("start", machine_name)
    }

    if System.command_failed?
      $stderr.puts err
      raise("There was an error bringing up the VM. Dinghy cannot continue.")
    end

    write_ssh_config!
  end

  def host_ip
    vm_ip.sub(%r{\.\d+$}, '.1')
  end

  def vm_ip
    inspect['Driver']['IPAddress']
  end

  def provider
    inspect['DriverName']
  end

  def store_path
    driver = inspect['Driver']
    if driver.key?('StorePath')
      File.join(driver['StorePath'], 'machines', driver['MachineName'])
    else
      inspect['StorePath']
    end
  end

  def inspect
    JSON.parse(`docker-machine inspect #{machine_name} 2>/dev/null`)
  end

  def status
    if created?
      `docker-machine status #{machine_name}`.strip.downcase
    else
      "not created"
    end
  end

  def running?
    status == "running"
  end

  def mount(unfs)
    puts "Mounting NFS #{unfs.guest_mount_dir}"
    # Remove the existing vbox/vmware shared folder. There isn't an option yet
    # in docker-machine to skip creating the shared folder in the first place.
    ssh("sudo umount /Users || true")

    ssh("sudo mkdir -p #{unfs.guest_mount_dir}")
    ssh("sudo mount -t nfs #{host_ip}:#{unfs.host_mount_dir} #{unfs.guest_mount_dir} -o nfsvers=3,udp,mountport=#{unfs.port},port=#{unfs.port},nolock,hard,intr")
  end

  def ssh(*command)
    if command.empty?
      exec('ssh', machine_name)
    else
      system('ssh', machine_name, '--', *command)
      fail CommandFailed.new("Error executing command: #{command}", $?.exitstatus) unless $?.success?
    end
  end

  def write_ssh_config!
    File.open(ssh_config_path, 'wb') { |f| f.write(ssh_config) }
  end

  def ssh_config
    # Constructing the IdentityFile path ourselves is a recipe for future
    # sadness, but I haven't found a way to get it out of docker-machine.
    <<-SSH
Host dinghy
  HostName #{vm_ip}
  User docker
  Port 22
  UserKnownHostsFile /dev/null
  StrictHostKeyChecking no
  PasswordAuthentication no
  IdentityFile #{store_path}/id_rsa
  IdentitiesOnly yes
  LogLevel ERROR
    SSH
  end

  def halt
    system("stop", machine_name)
  end

  def upgrade
    system("upgrade", machine_name)
  end

  def destroy(options = {})
    system(*["rm", (options[:force] ? '--force' : nil), machine_name].compact)
  end

  def created?
    `docker-machine status #{machine_name} 2>&1`
    !System.command_failed?
  end

  def system(*cmd)
    Kernel.system("docker-machine", *cmd)
  end

  def exec(*cmd)
    Kernel.exec('docker-machine', *cmd)
  end

  def machine_name
    'dinghy'
  end
  alias :name :machine_name

  def translate_provider(name)
    case name
    when "virtualbox"
      "virtualbox"
    when "vmware", "vmware_fusion", "vmwarefusion", "vmware_desktop"
      "vmwarefusion"
    else
      nil
    end
  end

  protected

  def ssh_config_path
    # this is hard-coded inside the fsevents_to_vm plist, as well
    HOME_DINGHY+"ssh-config"
  end

  def configure_new_machine(provider)
    if provider == "virtualbox"
      halt
      # force host DNS resolving, so that *.docker resolves inside containers
      Kernel.system("VBoxManage", "modifyvm", machine_name, "--natdnshostresolver1", "on")

      if System.command_failed?
        raise("There was an error configuring the VM.")
      end
      up
    end
  end
end

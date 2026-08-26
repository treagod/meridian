require "base64"
require "file_utils"

module Meridian
  module Server
    record BootstrapConfig,
      host : String,
      port : Int32,
      root_user : String,
      deploy_user : String,
      public_key_file : String,
      private_key_file : String,
      accept_new_host_key : Bool,
      rootless_low_ports : Bool,
      rootless_port_start : Int32,
      transfer_mode : Config::TransferMode?

    class Bootstrapper
      BASE_PACKAGES = [
        "ca-certificates",
        "curl",
        "podman",
        "uidmap",
        "slirp4netns",
        "fuse-overlayfs",
      ]

      abstract class Runner
        abstract def run_interactive(command : String, args : Array(String), step : String) : Nil
        abstract def run_check(command : String, args : Array(String), step : String) : Bool
      end

      class ProcessRunner < Runner
        def initialize(@output : IO = STDOUT, @error : IO = STDERR)
        end

        def run_interactive(command : String, args : Array(String), step : String) : Nil
          @output.puts "\n==> #{step}"
          @output.puts "$ #{command} #{args.join(" ")}"
          status = Process.run(command, args, input: STDIN, output: @output, error: @error)
          raise BootstrapError.new("#{step} failed with exit code #{status.exit_code}") unless status.success?
        end

        def run_check(command : String, args : Array(String), step : String) : Bool
          @output.puts "\n==> #{step}"
          @output.puts "$ #{command} #{args.join(" ")}"
          Process.run(command, args, input: STDIN, output: @output, error: @error).success?
        end
      end

      def initialize(
        @config : BootstrapConfig,
        runner : Runner? = nil,
        @output : IO = STDOUT,
      )
        @runner = runner || ProcessRunner.new(@output)
      end

      def bootstrap : Nil
        public_key = File.read(@config.public_key_file).strip
        raise BootstrapError.new("Public key file is empty: #{@config.public_key_file}") if public_key.empty?
        public_key_b64 = Base64.strict_encode(public_key)

        script_local = write_temp_script("meridian-bootstrap", provision_script(public_key_b64))
        script_remote = "/tmp/#{File.basename(script_local)}"

        print_banner

        begin
          upload_as_root(script_local, script_remote)
          execute_as_root(script_remote, "Provision #{@config.host} as #{@config.root_user}")

          unless test_deploy_login
            raise BootstrapError.new(
              "Deploy SSH login test failed — nothing about SSH access was changed, " \
              "safe to fix the key and rerun"
            )
          end

          create_deploy_directories

          print_success_summary
        ensure
          FileUtils.rm_rf(script_local)
        end
      end

      private def print_banner : Nil
        @output.puts <<-TEXT

          This script will:
            1. Connect to #{@config.root_user}@#{@config.host} for the initial bootstrap (password prompt).
            2. Install Podman, rootless helpers, and #{transfer_package_summary}.
            3. Create '#{@config.deploy_user}', install your SSH public key, and enable lingering.
            4. #{@config.rootless_low_ports ? "Allow rootless services to bind ports >= #{@config.rootless_port_start}." : "Leave low-port binding unchanged."}
            5. Verify key-based SSH login for '#{@config.deploy_user}'.
            6. Create rootless Podman directories for '#{@config.deploy_user}'.

          Notes:
            - The first SSH/SCP steps will prompt for the #{@config.root_user} password interactively.
            - Firewall rules, SSH hardening, and unattended upgrades are left untouched — see below.
          TEXT
      end

      private def print_success_summary : Nil
        @output.puts <<-TEXT

          Bootstrap completed successfully.

          You can now log in with:
            ssh -i #{@config.private_key_file} #{@config.deploy_user}@#{@config.host}

          Meridian deliberately left your server policy alone. It did not configure a
          firewall, change any sshd setting, or enable unattended upgrades. If you want
          those, set them up yourself — the proxy needs inbound 80/443, and Meridian
          needs inbound #{@config.port}/tcp for SSH.

          Recommended next steps:
            - Verify rootless Podman as #{@config.deploy_user}: podman info
            - Run: meridian setup
          TEXT
      end

      private def write_temp_script(name : String, content : String) : String
        path = File.join(Dir.tempdir, "#{name}-#{Process.pid}-#{Time.utc.to_unix_ms}.sh")
        File.write(path, content)
        File.chmod(path, 0o600)
        path
      end

      private def ssh_base_options : Array(String)
        opts = [] of String
        opts << "-p" << @config.port.to_s
        opts << "-o" << "ConnectTimeout=10"
        opts << "-o" << "ServerAliveInterval=30"
        opts << "-o" << "ServerAliveCountMax=3"
        opts << "-o" << (@config.accept_new_host_key ? "StrictHostKeyChecking=accept-new" : "StrictHostKeyChecking=yes")
        opts
      end

      private def scp_base_options : Array(String)
        opts = [] of String
        opts << "-P" << @config.port.to_s
        opts << "-o" << "ConnectTimeout=10"
        opts << "-o" << "ServerAliveInterval=30"
        opts << "-o" << "ServerAliveCountMax=3"
        opts << "-o" << (@config.accept_new_host_key ? "StrictHostKeyChecking=accept-new" : "StrictHostKeyChecking=yes")
        opts
      end

      private def deploy_key_options : Array(String)
        ["-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-i", @config.private_key_file]
      end

      private def create_deploy_directories : Nil
        args = ssh_base_options
        args.concat(deploy_key_options)
        args << "#{@config.deploy_user}@#{@config.host}"
        args << "mkdir -p ~/.config/containers/systemd ~/.local/share/containers"
        @runner.run_interactive("ssh", args, "Create deploy directories as #{@config.deploy_user}")
      end

      private def upload_as_root(local : String, remote : String) : Nil
        args = scp_base_options
        args.concat(["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"])
        args << local
        args << "#{@config.root_user}@#{@config.host}:#{remote}"
        @runner.run_interactive("scp", args, "Upload #{File.basename(local)} as #{@config.root_user}")
      end

      private def execute_as_root(remote : String, step : String) : Nil
        args = ssh_base_options
        args << "-tt"
        args.concat(["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"])
        args << "#{@config.root_user}@#{@config.host}"
        args << "bash #{remote} && rm -f #{remote}"
        @runner.run_interactive("ssh", args, step)
      end

      private def test_deploy_login : Bool
        args = ssh_base_options
        args.concat(deploy_key_options)
        args << "#{@config.deploy_user}@#{@config.host}"
        args << "true"
        @runner.run_check("ssh", args, "Test SSH key login for #{@config.deploy_user}")
      end

      private def provision_script(public_key_b64 : String) : String
        <<-BASH
          #!/usr/bin/env bash
          set -euo pipefail

          export DEBIAN_FRONTEND=noninteractive

          DEPLOY_USER=#{@config.deploy_user.inspect}
          PUBKEY_B64=#{public_key_b64.inspect}
          ROOTLESS_LOW_PORTS=#{(@config.rootless_low_ports ? "yes" : "no").inspect}
          ROOTLESS_PORT_START=#{@config.rootless_port_start.to_s.inspect}

          apt-get update
          apt-get install -y #{package_install_list}

          if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
            useradd --create-home --shell /bin/bash "$DEPLOY_USER"
          fi

          HOME_DIR="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"
          SSH_DIR="$HOME_DIR/.ssh"
          AUTH_KEYS="$SSH_DIR/authorized_keys"

          install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$SSH_DIR"
          touch "$AUTH_KEYS"
          chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
          chmod 600 "$AUTH_KEYS"

          PUBKEY_FILE="$(mktemp)"
          trap 'rm -f "$PUBKEY_FILE"' EXIT
          printf '%s' "$PUBKEY_B64" | base64 -d > "$PUBKEY_FILE"
          PUBKEY_CONTENT="$(cat "$PUBKEY_FILE")"

          if ! grep -qxF "$PUBKEY_CONTENT" "$AUTH_KEYS"; then
            cat "$PUBKEY_FILE" >> "$AUTH_KEYS"
            printf '\\n' >> "$AUTH_KEYS"
          fi

          chown "$DEPLOY_USER:$DEPLOY_USER" "$AUTH_KEYS"
          chmod 600 "$AUTH_KEYS"

          if ! grep -qE "^${DEPLOY_USER}:" /etc/subuid; then
            echo "${DEPLOY_USER}:100000:65536" >> /etc/subuid
          fi

          if ! grep -qE "^${DEPLOY_USER}:" /etc/subgid; then
            echo "${DEPLOY_USER}:100000:65536" >> /etc/subgid
          fi

          loginctl enable-linger "$DEPLOY_USER"

          if [ "$ROOTLESS_LOW_PORTS" = "yes" ]; then
            cat > /etc/sysctl.d/99-rootless-low-ports.conf <<EOF
          net.ipv4.ip_unprivileged_port_start=${ROOTLESS_PORT_START}
          EOF
            sysctl --system >/dev/null
          fi

          echo
          echo "Provisioning complete. Deploy user '$DEPLOY_USER' is prepared."
          BASH
      end

      private def package_install_list : String
        provision_packages.map(&.inspect).join(" ")
      end

      private def provision_packages : Array(String)
        transfer_mode = @config.transfer_mode

        if transfer_mode.try(&.stream?)
          BASE_PACKAGES + ["zstd"]
        elsif transfer_mode.try(&.incremental?)
          BASE_PACKAGES + ["zstd", "rsync", "skopeo"]
        else
          BASE_PACKAGES.dup
        end
      end

      private def transfer_package_summary : String
        transfer_mode = @config.transfer_mode

        if transfer_mode.try(&.stream?)
          "stream-transfer tools (zstd)"
        elsif transfer_mode.try(&.incremental?)
          "incremental-transfer tools (zstd, rsync, skopeo)"
        else
          "no extra transfer packages for registry pulls"
        end
      end
    end
  end
end

require 'ec2'
require 'yaml'
require 'socket'

class Sumo
	def launch
		ami = config['ami']
		raise "No AMI selected" unless ami

		create_keypair unless File.exists? keypair_file

		result = ec2.run_instances(
			:image_id => ami,
			:instance_type => config['instance_size'] || 'm1.small',
			:availability_zone => config['availability_zone'] || 'us-east-1b',
			:key_name => 'sumo'
		)
		result.instancesSet.item[0].instanceId
	end

	def list
		@list ||= fetch_list
	end

	def fetch_list
		result = ec2.describe_instances
		return [] unless result.reservationSet

		instances = []
		result.reservationSet.item.each do |r|
			r.instancesSet.item.each do |item|
				instances << {
					:instance_id => item.instanceId,
					:status => item.instanceState.name,
					:hostname => item.dnsName
				}
			end
		end
		instances
	end

	def find(id_or_hostname)
		return unless id_or_hostname
		id_or_hostname = id_or_hostname.strip.downcase
		list.detect do |inst|
			inst[:hostname] == id_or_hostname or
			inst[:instance_id] == id_or_hostname or
			inst[:instance_id].gsub(/^i-/, '') == id_or_hostname
		end
	end

	def running
		list_by_status('running')
	end

	def pending
		list_by_status('pending')
	end

	def list_by_status(status)
		list.select { |i| i[:status] == status }
	end

	def instance_info(instance_id)
		fetch_list.detect do |inst|
			inst[:instance_id] == instance_id
		end
	end

	def wait_for_hostname(instance_id)
		raise ArgumentError unless instance_id and instance_id.match(/^i-/)
		loop do
			if inst = instance_info(instance_id)
				if hostname = inst[:hostname]
					return hostname
				end
			end
			sleep 1
		end
	end

	def wait_for_ssh(hostname)
		raise ArgumentError unless hostname
		loop do
			begin
				Timeout::timeout(4) do
					TCPSocket.new(hostname, 22)
					return
				end
			rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::EHOSTUNREACH
			end
		end
	end

	def bootstrap_chef(hostname)
		commands = [
			'apt-get update',
			'apt-get autoremove -y',
			'apt-get install -y ruby ruby-dev rubygems git-core',
			'gem sources -a http://gems.opscode.com',
			'gem install chef ohai --no-rdoc --no-ri',
			"git clone #{config['cookbooks_url']}",
		]
		ssh(hostname, commands)
	end

	def setup_role(hostname, role)
		commands = [
			"cd chef-cookbooks",
			"/var/lib/gems/1.8/bin/chef-solo -c config.json -j roles/#{role}.json"
		]
		ssh(hostname, commands)
	end

	def ssh(hostname, cmds)
		IO.popen("ssh -i #{keypair_file} root@#{hostname} > ~/.sumo/ssh.log 2>&1", "w") do |pipe|
			pipe.puts cmds.join(' && ')
		end
		unless $?.success?
			abort "failed\nCheck ~/.sumo/ssh.log for the output"
		end
	end

	def fetch_resources(hostname)
		cmd = "ssh -i #{keypair_file} root@#{hostname} 'cat /root/resources' 2>&1"
		out = IO.popen(cmd, 'r') { |pipe| pipe.read }
		abort "failed to read resources, output:\n#{out}" unless $?.success?
		parse_resources(out, hostname)
	end

	def parse_resources(raw, hostname)
		raw.split("\n").map do |line|
			line.gsub(/localhost/, hostname)
		end
	end

	def terminate(instance_id)
		ec2.terminate_instances(:instance_id => [ instance_id ])
	end

	def console_output(instance_id)
		ec2.get_console_output(:instance_id => instance_id)["output"]
	end

	def config
		@config ||= read_config
	end

	def sumo_dir
		"#{ENV['HOME']}/.sumo"
	end

	def read_config
		YAML.load File.read("#{sumo_dir}/config.yml")
	rescue Errno::ENOENT
		raise "Sumo is not configured, please fill in ~/.sumo/config.yml"
	end

	def keypair_file
		"#{sumo_dir}/keypair.pem"
	end

	def create_keypair
		keypair = ec2.create_keypair(:key_name => "sumo").keyMaterial
		File.open(keypair_file, 'w') { |f| f.write keypair }
		File.chmod 0600, keypair_file
	end

	def ec2
		@ec2 ||= EC2::Base.new(:access_key_id => config['access_id'], :secret_access_key => config['access_secret'])
	end
end

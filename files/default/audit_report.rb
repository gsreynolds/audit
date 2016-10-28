require 'chef/handler'
include ReportHelpers

class Chef
  class Handler
    # Creates a compliance audit report
    class AuditReport < ::Chef::Handler
      def report
        reporter = node['audit']['collector']
        server = node['audit']['server']
        user = node['audit']['owner']
        token = node['audit']['token']
        refresh_token = node['audit']['refresh_token']
        interval = node['audit']['interval']
        interval_enabled = node['audit']['interval']['enabled']
        interval_time = node['audit']['interval']['time']
        report_file = node['audit']['output']

        load_needed_dependencies

        # ensure authentication for Chef Compliance is in place
        login_to_compliance(server, user, token, refresh_token) if reporter == 'chef-compliance'

        if check_interval_settings(interval, interval_enabled, interval_time, report_file)
          call(reporter)
          send_report(reporter, server, user)
        else
          Chef::Log.error 'Please take a look at your interval settings'
        end
      end

      def load_needed_dependencies
        require 'inspec'
        # load supermarket plugin, this is part of the inspec gem
        require 'bundles/inspec-supermarket/api'
        require 'bundles/inspec-supermarket/target'

        # load the compliance plugin
        require 'bundles/inspec-compliance/configuration'
        require 'bundles/inspec-compliance/support'
        require 'bundles/inspec-compliance/http'
        require 'bundles/inspec-compliance/api'
        require 'bundles/inspec-compliance/target'
      end

      # TODO: temporary, we should not use this
      # TODO: harmonize with CLI login_refreshtoken method
      def login_to_compliance(server, user, access_token, refresh_token)
        if !refresh_token.nil?
          success, msg, access_token = Compliance::API.get_token_via_refresh_token(server, refresh_token, true)
        else
          success = true
        end

        if success
          config = Compliance::Configuration.new
          config['user'] = user
          config['server'] = server
          config['token'] = access_token
          config['insecure'] = true
          config['version'] = Compliance::API.version(server, true)
          config.store
        else
          Chef::Log.error msg
          raise('Could not store authentication token')
        end
      end

      def check_interval_settings(interval, interval_enabled, interval_time, report_file)
        # handle intervals
        interval_seconds = 0 # always run this by default, unless interval is defined
        if !interval.nil? && interval_enabled
          interval_seconds = interval_time * 60 # seconds in interval
          Chef::Log.debug "Auditing this machine every #{interval_seconds} seconds "
        end
        # returns true if profile is overdue to run
        profile_overdue_to_run?(interval_seconds, report_file)
      end

      def call(reporter)
        Chef::Log.debug 'Initialize InSpec'
        format = reporter == 'chef-visibility' ? 'json' : 'json-min'
        Chef::Log.warn "Format is  #{format}"
        # TODO: for now we need to store the report to a file we expect that to
        # get from the runner
        Chef::Log.warn "*********** Directory is  #{node['audit']['output']}"
        opts = { 'format' => format, 'output' => node['audit']['output'] }
        runner = ::Inspec::Runner.new(opts)

        tests = tests_for_runner
        tests.each { |target| runner.add_target(target, opts) }

        Chef::Log.info "Running tests from: #{tests.inspect}"
        runner.run
      end

      # extracts relevant node data
      def gather_nodeinfo
        n = run_context.node
        {
          node: n.name,
          os: {
            # arch: n['arch'],
            release: n['platform_version'],
            family: n['platform'],
          },
          environment: n.environment,
        }
      end

      def send_report(reporter, server, user)
        Chef::Log.info "Reporting to #{reporter}"

        # TODO: harmonize reporter interface
        if reporter == 'chef-visibility'
          Collector::ChefVisibility.new(entity_uuid, run_id, gather_nodeinfo[:node]).send_report

        elsif reporter == 'chef-compliance'
          raise_if_unreachable = node['audit']['raise_if_unreachable']
          url = construct_url(server, File.join('/owners', user, 'inspec'))
          if server
            # TODO: we should not send the profiles to the reporter, all the information
            # should be available in inspec reports out-of-the-box
            # TODO: Chef Compliance can only handle reports for profiles it knows
            profiles = tests_for_runner.map { |profile| profile[:compliance] }.uniq
            compliance_profiles = profiles.map { |profile|
              owner, profile_id = profile.split('/')
              {
                owner: owner,
                profile_id: profile_id,
              }
            }
            Collector::ChefCompliance.new(url, gather_nodeinfo, raise_if_unreachable, compliance_profiles).send_report
          else
            Chef::Log.warn "'server' and 'token' properties required by inspec report collector #{reporter}. Skipping..."
          end

        elsif reporter == 'chef-server'
          chef_url = server || base_chef_server_url
          if chef_url
            url = construct_url(chef_url + '/compliance/', File.join('organizations', user, 'inspec'))
            Collector::ChefServer.new(url).send_report
          else
            Chef::Log.warn "unable to determine chef-server url required by inspec report collector '#{reporter}'. Skipping..."
          end
        else
          Chef::Log.warn "#{reporter} is not a supported InSpec report collector"
        end
      end
    end
  end
end

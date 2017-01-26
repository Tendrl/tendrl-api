require 'tendrl'

class Base < Sinatra::Base
  set :root, File.dirname(__FILE__)

  set :environment, ENV['RACK_ENV'] || 'development'

  set :logging, true

  set :logging, ENV['LOG_LEVEL'] || Logger::INFO

  configure :development, :test do
    set :etcd_config, Proc.new {
      YAML.load_file('config/etcd.yml')[settings.environment.to_sym] 
    }
  end

  configure :production do
    set :etcd_config, Proc.new {
      if File.exists?('/etc/tendrl/etcd.yml')
        YAML.load_file('/etc/tendrl/etcd.yml')[settings.environment.to_sym] 
      else
        YAML.load_file('config/etcd.yml')[settings.environment.to_sym] 
      end
    }
  end

  set :http_allow_methods, [
    'POST',
    'GET',
    'OPTIONS',
    'PUT',
    'DELETE'
  ]

  set :http_allow_headers, [
    'Origin',
    'Content-Type',
    'Accept',
    'Authorization',
    'X-Requested-With'
  ]

  set :http_allow_origin, [
    '*'
  ]

  set :etcd, Proc.new {
    Etcd.client(
      host: etcd_config[:host],
      port: etcd_config[:port],
      user_name: etcd_config[:user_name],
      password: etcd_config[:password]
    )
  }

  error Etcd::NotDir do
    halt 404, { errors: { message: 'Not found.' }}.to_json
  end

  error Etcd::KeyNotFound do
    halt 404, { errors: { message: 'Not found.' }}.to_json
  end

  before do
    content_type :json
    response.headers["Access-Control-Allow-Origin"] = 
      settings.http_allow_origin.join(',')
    response.headers["Access-Control-Allow-Methods"] = 
      settings.http_allow_methods.join(',')
    response.headers["Access-Control-Allow-Headers"] = 
      settings.http_allow_headers.join(',')
  end

  get '/ping' do
    { 
      status: 'Ok'
    }.to_json
  end

  get '/jobs' do
    jobs = []
    etcd.get('/queue', recursive: true).children.each do |job|
      job = JSON.parse(job.value)
      jobs << JobPresenter.single(job) if job['created_from'] == 'API'
    end
    jobs.to_json
  end

  get '/jobs/:job_id' do
    jobs = []
    job = JSON.parse(etcd.get("/queue/#{params[:job_id]}").value)
    JobPresenter.single(job).to_json
  end

  get '/jobs/:job_id/logs' do
    params[:type] ||= 'all'
    job = JSON.parse(etcd.get("/queue/#{params[:job_id]}").value)
    request_id = job['request_id']
    logs = etcd.get("/#{request_id}/#{params[:type]}").value
    { logs: logs, type: params[:type] }.to_json
  end

  post '/ImportCluster' do
    flow = Tendrl::Flow.new('namespace.tendrl.node_agent', 'ImportCluster')
    body = JSON.parse(request.body.read)

    # ImportCluster job structure:
    #
    # job = {
    #   "integration_id": "9a4b84e0-17b3-4543-af9f-e42000c52bfc",
    #   "run": "tendrl.node_agent.flows.import_cluster.ImportCluster",
    #   "status": "new",
    #   "type": "node",
    #   "node_ids": ["3943fab1-9ed2-4eb6-8121-5a69499c4568"],
    #   "parameters": {
    #     "TendrlContext.integration_id": "6b4b84e0-17b3-4543-af9f-e42000c52bfc",
    #     "Node[]": ["3943fab1-9ed2-4eb6-8121-5a69499c4568"],
    #     "DetectedCluster.sds_pkg_name": "gluster"
    #   }
    # }

    missing_params = []
    ['DetectedCluster.sds_pkg_name', 'Node[]'].each do |param|
      missing_params << param unless body[param] and not body[param].empty?
    end
    halt 401, "Missing parameters: #{missing_params.join(', ')}" unless missing_params.empty?

    node_ids = body['Node[]']
    halt 401, "Node[] must be an array with values" unless node_id.kind_of?(Array) and not node_id.empty?

    body['TendrlContext.integration_id'] = SecureRandom.uuid
    job_id = SecureRandom.uuid

    etcd.set(
      "/queue/#{job_id}",
      value: {
        integration_id: body['TendrlContext.integration_id'],
        job_id: job_id,
        status: 'new',
        parameters: body,
        run: flow.run,
        flow: flow.flow_name,
        type: 'node',
        created_from: 'API',
        created_at: Time.now.utc.iso8601,
        node_ids: node_ids
      }.to_json
    )

    status 202
    { job_id: job_id }.to_json
  end

  protected

  def monitoring
    yaml = etcd.get('/_tendrl/config/performance_monitoring').value
    config = YAML.load(yaml)
    @monitoring = Tendrl::MonitoringApi.new(config)
  rescue Etcd::KeyNotFound
    logger.info 'Monitoring API not enabled.'
    nil
  end

  def etcd
    settings.etcd
  end

  def recurse(parent, attrs={})
    parent_key = parent.key.split('/')[-1].downcase
    return attrs if ['definitions', 'raw_map'].include?(parent_key)
    parent.children.each do |child|
      child_key = child.key.split('/')[-1].downcase
      attrs[parent_key] ||= {}
      if child.dir
        recurse(child, attrs[parent_key])
      else
        if attrs[parent_key]
          attrs[parent_key][child_key] = child.value
        else
          attrs[child_key] = child.value
        end
      end
    end
    attrs
  end
  

end

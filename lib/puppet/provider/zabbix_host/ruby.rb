require_relative '../zabbix'
Puppet::Type.type(:zabbix_host).provide(:ruby, parent: Puppet::Provider::Zabbix) do
  confine feature: :zabbixapi

  def self.instances
    proxies = zbx.proxies.all
    api_hosts = zbx.query(
      method: 'host.get',
      params: {
        selectParentTemplates: ['host'],
        selectInterfaces: %w[interfaceid type main ip port useip],
        selectGroups: ['name'],
        selectMacros: %w[macro value],
        selectHttpTests: ['httptestid'],
        output: %w[host proxy_hostid inventory_mode]
      }
    )

    api_hosts.map do |h|
      # only select the default interface for given host
      # there is only 1 interface that can be default
      Puppet.debug("Host: #{h}")
      next if h['interfaces'].nil? or h['interfaces'].empty? or !h['interfaces'].length
      interface = h['interfaces'].select { |i| i['main'].to_i == 1 }.first
      use_ip = !interface['useip'].to_i.zero?
      proxy_select = proxies.select { |_name, id| id == h['proxy_hostid'] }.keys.first
      proxy_select = '' if proxy_select.nil?
      webids = h['httpTests'].map { |x| x['httptestid'] }
      webservicesjson = zbx.query(
        method: 'httptest.get',
        params: {
          httptestids: webids,
          selectSteps: %w[name url status_codes],
          output: ['name']
        }
      )
      new(
        ensure: :present,
        id: h['hostid'].to_i,
        name: h['host'],
        interfaceid: interface['interfaceid'].to_i,
        ipaddress: interface['ip'],
        use_ip: use_ip,
        port: interface['port'].to_i,
        groups: h['groups'].map { |g| g['name'] },
        group_create: nil,
        templates: h['parentTemplates'].map { |x| x['host'] },
        macros: h['macros'].map { |macro| { macro['macro'] => macro['value'] } },
        webservices: webservicesjson.map { |web| { 'name' => web['name'], 'steps' => web['steps'] } },
        proxy: proxy_select,
        inventory_mode: h['inventory_mode'],
        interfacetype: interface['type'].to_i
      )
    end
  end

  def self.prefetch(resources)
    instances.each do |prov|
      next if prov.nil?
      if (resource = resources[prov.name])
        resource.provider = prov
      end
    end
  end

  def create
    template_ids = get_templateids(@resource[:templates])
    templates = transform_to_array_hash('templateid', template_ids)

    gids = get_groupids(@resource[:groups], @resource[:group_create])
    groups = transform_to_array_hash('groupid', gids)

    proxy_hostid = @resource[:proxy].nil? || @resource[:proxy].empty? ? nil : zbx.proxies.get_id(host: @resource[:proxy])

    # Now we create the host
    zbx.hosts.create(
      host: @resource[:hostname],
      proxy_hostid: proxy_hostid,
      interfaces: [
        {
          type: @resource[:interfacetype].nil? ? 1 : @resource[:interfacetype],
          main: 1,
          ip: @resource[:ipaddress],
          dns: @resource[:hostname],
          port: @resource[:port],
          useip: @resource[:use_ip] ? 1 : 0
        }
      ],
      templates: templates,
      groups: groups,
      inventory_mode: @resource[:inventory_mode].nil? ? -1 : @resource[:inventory_mode]
    )
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  def destroy
    zbx.hosts.delete(zbx.hosts.get_id(host: @resource[:hostname]))
  end

  #
  # Helper methods
  #
  def get_groupids(group_array, create)
    groupids = []
    group_array.each do |g|
      id = zbx.hostgroups.get_id(name: g)
      if id.nil?
        raise Puppet::Error, 'The hostgroup (' + g + ') does not exist in zabbix. Please use the correct one or set group_create => true.' unless create
        groupids << zbx.hostgroups.create(name: g)
      else
        groupids << id
      end
    end
    groupids
  end

  def get_templateids(template_array)
    templateids = []
    template_array.each do |t|
      template_id = zbx.templates.get_id(host: t)
      raise Puppet::Error, "The template #{t} does not exist in Zabbix. Please use a correct one." if template_id.nil?
      templateids << template_id
    end
    templateids
  end

  #
  # zabbix_host properties
  #
  mk_resource_methods

  def ipaddress=(string)
    zbx.query(
      method: 'hostinterface.update',
      params: {
        interfaceid: @property_hash[:interfaceid],
        ip: string
      }
    )
  end

  def use_ip=(boolean)
    zbx.query(
      method: 'hostinterface.update',
      params: {
        interfaceid: @property_hash[:interfaceid],
        useip: boolean ? 1 : 0,
        dns: @resource[:hostname]
      }
    )
  end

  def port=(int)
    zbx.query(
      method: 'hostinterface.update',
      params: {
        interfaceid: @property_hash[:interfaceid],
        port: int
      }
    )
  end

  def interfacetype=(int)
    zbx.query(
      method: 'hostinterface.update',
      params: {
        interfaceid: @property_hash[:interfaceid],
        type: int
      }
    )
  end

  def groups=(hostgroups)
    gids = get_groupids(hostgroups, @resource[:group_create])
    groups = transform_to_array_hash('groupid', gids)

    zbx.hosts.create_or_update(
      host: @resource[:hostname],
      groups: groups
    )
  end

  def templates=(array)
    should_template_ids = get_templateids(array)

    # Get templates we have to clear. Unlinking only isn't really helpful.
    is_template_ids = zbx.query(
      method: 'host.get',
      params: {
        hostids: @property_hash[:id],
        selectParentTemplates: ['templateid'],
        output: ['host']
      }
    ).first['parentTemplates'].map { |t| t['templateid'].to_i }
    templates_clear = is_template_ids - should_template_ids

    zbx.query(
      method: 'host.update',
      params: {
        hostid: @property_hash[:id],
        templates: transform_to_array_hash('templateid', should_template_ids),
        templates_clear: transform_to_array_hash('templateid', templates_clear)
      }
    )
  end

  def macros=(array)
    macroarray = array.map { |macro| { 'macro' => macro.first[0], 'value' => macro.first[1] } }
    zbx.query(
      method: 'host.update',
      params: {
        hostid: @property_hash[:id],
        macros: macroarray
      }
    )
  end

  def proxy=(string)
    zbx.hosts.create_or_update(
      host: @resource[:hostname],
      proxy_hostid: zbx.proxies.get_id(host: string)
    )
  end

  def webservices=(array)
    existing = zbx.query(
      method: 'httptest.get',
      params: {
        hostids: @property_hash[:id],
        output: 'extend',
        selectSteps: 'extend'
      }
    ).map { |webservice| { 'httptestid' => webservice['httptestid'], 'name' => webservice['name'], 'steps' => webservice['steps'].map { |step| { 'url' => step['url'], 'name' => step['name'], 'status_codes' => step['status_codes'] } } } }
    webs_clear = []
    webs_same = []
    existing.each do |web|
      web_copy = Hash.new
      web.each do |pair|
        if(pair[0] != 'httptestid')
          web_copy.store(pair[0], pair[1])
        end
      end
      if(array.include? web_copy)
        webs_same.push(web_copy)
      else
        webs_clear.push(web)
      end
    end
    webs_new = array - webs_same
    if webs_clear.any?
      zbx.query(
        method: 'httptest.delete',
        params: webs_clear.map { |web| web['httptestid'] }
      )
    end
    webs_new.each do |web|
      no = 0
      zbx.query(
        method: 'httptest.create',
        params: {
          hostid: @property_hash[:id],
          name: web['name'],
          steps: web['steps'].map { |step| {'name' => step['name'], 'url' => step['url'], 'status_codes' => step['status_codes'], 'no' => (no += 1)} }
        }
      )
    end
  end

  def inventory_mode=(int)
    zbx.hosts.create_or_update(
      host: @resource[:hostname],
      inventory_mode: int
    )
  end
end

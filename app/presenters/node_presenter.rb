module NodePresenter
  class << self
    def list(nodes_list)
      nodes = []
      nodes_list.each do |node|
        node.each do |_, attributes|
          attributes.slice!('nodecontext','tendrlcontext')
          node_attr = attributes.delete('nodecontext')
          next if node_attr.blank?
          if cluster = attributes.delete('tendrlcontext')
            cluster.delete('node_id')
          end
          node_attr.delete('tags')
          nodes << node_attr.merge(attributes).merge(cluster: (cluster || {}))
        end
      end
      nodes
    end
  end
end

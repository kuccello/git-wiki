Engine.create(:fileinfo, :priority => 4, :layout => true, :cacheable => true) do
  def output(context)
    @resource = context.page
    haml :fileinfo, :layout => false
  end
end

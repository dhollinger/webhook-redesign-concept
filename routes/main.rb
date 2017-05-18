class Webhook < Sinatra::Base
  get '/' do
    raise Sinatra::NotFound
  end

  get '/heartbeat' do
    return 200,  {:status => :success, :message => 'running' }.to_json
  end

  not_found do
    halt 404, "You shall not pass! (page not found)\n"
  end
end
module WebhookSlack
  @config = WEBHOOK_CONFIG
  
  def notify_slack(status_message)
    if config['slack_channel']
      slack_channel = @config['slack_channel']
    else
      slack_channel = '#default'
    end

    if @config['slack_username']
      slack_user = @config['slack_username']
    else
      slack_user = 'r10k'
    end

    if @config['slack_proxy_url']
      uri = URI(@config['slack_proxy_url'])
      http_options = {
          proxy_address:  uri.hostname,
          proxy_port:     uri.port,
          proxy_from_env: false
      }
    else
      http_options = {}
    end

    notifier = Slack::Notifier.new @config['slack_webhook'] do
      defaults channel: slack_channel,
               username: slack_user,
               icon_emoji: ":ocean:",
               http_options: http_options
    end

    if status_message[:branch]
      target = status_message[:branch]
    elsif status_message[:module]
      target = status_message[:module]
    end

    message = {
        author: 'r10k for Puppet',
        title: "r10k deployment of Puppet environment #{target}"
    }

    case status_message[:status_code]
      when 200
        message.merge!(
            color: "good",
            text: "Successfully deployed #{target}",
            fallback: "Successfully deployed #{target}"
        )
      when 500
        message.merge!(
            color: "bad",
            text: "Failed to deploy #{target}",
            fallback: "Failed to deploy #{target}"
        )
    end

    notifier.post text: message[:fallback], attachments: [message]
  end

  def slack?
    !!@config['slack_webhook']
  end
end
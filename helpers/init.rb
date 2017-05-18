require_relative 'main'
Webhook.helpers Webhook::Main

require_relative 'r10k'
Webhook.helpers Webhook::R10k

require_relative 'slack'
Webhook.helpers Webhook::Slack
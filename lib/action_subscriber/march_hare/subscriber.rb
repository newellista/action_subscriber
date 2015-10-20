module ActionSubscriber
  module MarchHare
    module Subscriber
      def auto_pop!
        # Because threadpools can be large we want to cap the number
        # of times we will pop each time we poll the broker
        times_to_pop = [::ActionSubscriber::Threadpool.ready_size, ::ActionSubscriber.config.times_to_pop].min
        times_to_pop.times do
          queues.each do |queue|
            metadata, encoded_payload = queue.pop(queue_subscription_options)
            next unless encoded_payload
            ::ActiveSupport::Notifications.instrument "popped_event.action_subscriber", :payload_size => encoded_payload.bytesize, :queue => queue.name
            properties = {
              :channel => queue.channel,
              :content_type => metadata.content_type,
              :delivery_tag => metadata.delivery_tag,
              :exchange => metadata.exchange,
              :headers => _normalized_headers(metadata),
              :message_id => metadata.message_id,
              :routing_key => metadata.routing_key,
            }
            env = ::ActionSubscriber::Middleware::Env.new(self, encoded_payload, properties)
            enqueue_env(env)
          end
        end

      rescue ::MarchHare::ChannelAlreadyClosed => e
        # The connection has gone down, we can just try again on the next pop
      end

      def auto_subscribe!
        queues.each do |queue|
          queue.channel.prefetch = ::ActionSubscriber.config.prefetch if acknowledge_messages?
          queue.subscribe(queue_subscription_options) do |metadata, encoded_payload|
            ::ActiveSupport::Notifications.instrument "received_event.action_subscriber", :payload_size => encoded_payload.bytesize, :queue => queue.name
            properties = {
              :channel => queue.channel,
              :content_type => metadata.content_type,
              :delivery_tag => metadata.delivery_tag,
              :exchange => metadata.exchange,
              :headers => _normalized_headers(metadata),
              :message_id => metadata.message_id,
              :routing_key => metadata.routing_key,
            }
            env = ::ActionSubscriber::Middleware::Env.new(self, encoded_payload, properties)
            enqueue_env(env)
          end
        end
      end

      private

      def enqueue_env(env)
        ::ActionSubscriber::Threadpool.pool.async(env) do |env|
          ::ActiveSupport::Notifications.instrument "process_event.action_subscriber", :subscriber => env.subscriber.to_s, :routing_key => env.routing_key do
            ::ActionSubscriber.config.middleware.call(env)
          end
        end
      end

      def _normalized_headers(metadata)
        return {} unless metadata.headers
        metadata.headers.each_with_object({}) do |(header,value), hash|
          hash[header] = value.to_s
        end
      end
    end
  end
end

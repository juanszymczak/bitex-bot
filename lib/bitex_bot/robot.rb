trap 'INT' do
  if BitexBot::Robot.graceful_shutdown
    print "\b"
    puts "Ok, ok, I'm out."
    exit 1
  end
  BitexBot::Robot.graceful_shutdown = true
  puts "Shutting down as soon as I've cleaned up."
end

module BitexBot
  # Documentation here!
  class Robot
    extend Forwardable

    cattr_accessor :taker
    cattr_accessor :maker
    cattr_accessor :graceful_shutdown
    cattr_accessor :cooldown_until
    cattr_accessor(:current_cooldowns) { 0 }
    cattr_accessor :logger

    def self.setup
      log(:info, :bot, :setup, 'Loading trading robot, ctrl+c *once* to exit gracefully.')

      self.logger = Logger.setup
      self.maker = Settings.maker_class.new(Settings.maker_settings)
      self.taker = Settings.taker_class.new(Settings.taker_settings)

      new
    end

    # Trade constantly respecting cooldown times so that we don't get banned by api clients.
    def self.run!
      bot = setup
      self.cooldown_until = Time.now
      loop do
        start_time = Time.now
        next if start_time < cooldown_until

        self.current_cooldowns = 0
        bot.trade!
        self.cooldown_until = start_time + current_cooldowns.seconds
      end
    end

    def self.sleep_for(seconds)
      sleep(seconds)
    end
    def_delegator self, :sleep_for

    def self.with_cooldown
      yield.tap do
        self.current_cooldowns += 1
        sleep_for(0.1)
      end
    end
    def_delegator self, :with_cooldown

    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def trade!
      sync_opening_flows if active_opening_flows?
      finalise_some_opening_flows
      shutdown! if shutdownable?
      start_closing_flows if open_positions?
      sync_closing_flows if active_closing_flows?

      return log(:debug, :bot, :trade, 'Not placing new orders, Store is hold') if store.reload.hold?
      return log(:debug, :bot, :trade, 'Not placing new orders, has active closing flows.') if active_closing_flows?
      return log(:debug, :bot, :trade, 'Not placing new orders, shutting down.') if turn_off?

      start_opening_flows_if_needed
    rescue CannotCreateFlow => e
      notify("#{e.class} - #{e.message}\n\n#{e.backtrace.join("\n")}")
      sleep_for(60 * 3)
    rescue Curl::Err::TimeoutError => e
      notify("#{e.class} - #{e.message}\n\n#{e.backtrace.join("\n")}")
      sleep_for(15)
    rescue OrderNotFound => e
      notify("#{e.class} - #{e.message}\n\n#{e.backtrace.join("\n")}")
    rescue ApiWrapperError => e
      notify("#{e.class} - #{e.message}\n\n#{e.backtrace.join("\n")}")
    rescue OrderArgumentError => e
      notify("#{e.class} - #{e.message}\n\n#{e.backtrace.join("\n")}")
    rescue StandardError => e
      notify("#{e.class} - #{e.message}\n\n#{e.backtrace.join("\n")}")
      sleep_for(60 * 2)
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    def active_closing_flows?
      [BuyClosingFlow, SellClosingFlow].map(&:active).any?(&:exists?)
    end

    def active_opening_flows?
      [BuyOpeningFlow, SellOpeningFlow].map(&:active).any?(&:exists?)
    end

    # The trader has a Store
    def store
      @store ||= Store.first || Store.create
    end

    def self.log(level, stage, step, details)
      logger.send(level, stage: stage, step: step, details: details)
    end
    def_delegator self, :log

    private

    def sync_opening_flows
      [BuyOpeningFlow, SellOpeningFlow].each(&:sync_positions)
    end

    def shutdownable?
      !(active_flows? || open_positions?) && turn_off?
    end

    def shutdown!
      log(:info, :bot, :shutdown, 'Shutdown completed')
      exit
    end

    def active_flows?
      active_opening_flows? || active_closing_flows?
    end

    def turn_off?
      self.class.graceful_shutdown
    end

    def finalise_some_opening_flows
      if turn_off?
        [BuyOpeningFlow, SellOpeningFlow].each { |kind| kind.active.each(&:finalise) }
      else
        threshold = Settings.time_to_live.seconds.ago.utc
        [BuyOpeningFlow, SellOpeningFlow].each { |kind| kind.old_active(threshold).each(&:finalise) }
      end
    end

    def start_closing_flows
      [BuyClosingFlow, SellClosingFlow].each(&:close_market)
    end

    def open_positions?
      [OpenBuy, OpenSell].map(&:open).any?(&:exists?)
    end

    def sync_closing_flows
      [BuyClosingFlow, SellClosingFlow].each(&:sync_positions)
    end

    def start_opening_flows_if_needed # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity
      recent_buying, recent_selling = recent_openings
      return log(:debug, :bot, :trade, 'Not placing new orders, recent ones exist.') if recent_buying && recent_selling

      maker_balance = with_cooldown { maker.balance }
      taker_balance = with_cooldown { taker.balance }

      store.sync(maker_balance, taker_balance)

      check_balance_warning if expired_last_warning?
      return if stop_opening_flows?

      taker_market = with_cooldown { taker.market }
      taker_transactions = with_cooldown { taker.transactions }

      OpeningFlow.store = store
      args = [taker_transactions, maker_balance.fee, taker_balance.fee]

      buying_args = [taker_balance.crypto.available, maker_balance.fiat.available, taker_market.bids] + args
      BuyOpeningFlow.open_market(*buying_args) unless recent_buying

      selling_args = [taker_balance.fiat.available, maker_balance.crypto.available, taker_market.asks] + args
      SellOpeningFlow.open_market(*selling_args) unless recent_selling
    end

    def recent_openings
      threshold = (Settings.time_to_live / 2).seconds.ago.utc

      [BuyOpeningFlow, SellOpeningFlow].map { |kind| kind.recents(threshold).first }
    end

    def expired_last_warning?
      store.last_warning.nil? || store.last_warning < 30.minutes.ago
    end

    # TODO: move to store responsibility
    def stop_opening_flows?
      if alert?(:fiat, :stop)
        log(:info, :bot, :stop, "Not placing new orders, #{maker.quote.upcase} target not met")
        return true
      end

      return false unless alert?(:crypto, :stop)

      log(:info, :bot, :stop, "Not placing new orders, #{maker.base.upcase} target not met")
      true
    end

    def check_balance_warning
      notify_balance_warning(maker.base, balance(:crypto), store.crypto_warning) if alert?(:crypto, :warning)
      notify_balance_warning(maker.quote, balance(:fiat), store.fiat_warning) if alert?(:fiat, :warning)
    end

    def alert?(currency, flag)
      return unless store.send("#{currency}_#{flag}").present?

      balance(currency) <= store.send("#{currency}_#{flag}")
    end

    def balance(currency)
      fx_rate = currency == :fiat ? Settings.buying_fx_rate : 1
      store.send("maker_#{currency}") / fx_rate + store.send("taker_#{currency}")
    end

    def notify_balance_warning(currency, amount, warning_amount)
      notify("#{currency.upcase} balance is too low, it's #{amount}, make it #{warning_amount} to stop this warning.")
      store.update(last_warning: Time.now)
    end

    def notify(message, subj = 'Notice from your robot trader')
      return unless Settings.mailer.present?

      log(:info, :bot, :trade, "Sending mail: { subject: #{subj}, error: #{message.split("\n").first} }")
      new_mail(subj, message).tap do |mail|
        mail.delivery_method(Settings.mailer.delivery_method, Settings.mailer.options.to_hash)
      end.deliver!
    end

    def new_mail(subj, message)
      Mail.new do
        from Settings.mailer.from
        to Settings.mailer.to
        subject subj
        body message
      end
    end
  end
end

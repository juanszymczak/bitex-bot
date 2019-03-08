module BitexBot
  # Any arbitrage workflow has 2 stages, opening positions and then closing them.
  # The OpeningFlow stage places an order on bitex, detecting and storing all transactions spawn from that order as
  # Open positions.
  class OpeningFlow < ActiveRecord::Base
    extend Forwardable

    self.abstract_class = true

    # The updated config store as passed from the robot
    cattr_accessor :store

    # @!group Statuses
    # All possible flow statuses
    # @return [Array<String>]
    cattr_accessor(:statuses) { %w[executing settling finalised] }

    def self.active
      where.not(status: :finalised)
    end

    def self.old_active
      active.where('created_at < ?', Settings.time_to_live.seconds.ago)
    end
    # @!endgroup

    # This use hooks methods, these must be defined in the subclass:
    #   #maker_price
    #   #order_class
    #   #remote_value_to_use
    #   #safest_price
    #   #value_to_use
    def self.open_market(taker_balance, maker_balance, taker_orders, taker_transactions, maker_fee, taker_fee, store)
      self.store = store

      unless enough_funds?(maker_balance, value_per_order)
        raise CannotCreateFlow,
              "Needed #{maker_specie_to_spend} #{value_per_order.truncate(8)} on #{Robot.maker.name} maker to place this "\
              "#{trade_type} but you only have #{maker_specie_to_spend} #{maker_balance.truncate(8)}."
      end

      taker_amount, safest_price = calc_taker_amount(taker_balance, maker_fee, taker_fee, taker_orders, taker_transactions)

      price = maker_price(taker_amount)
      order = Robot.maker.send_order(trade_type, price, value_per_order)

      create!(
        price: price,
        value_to_use: value_to_use,
        suggested_closing_price: safest_price,
        status: :executing,
        order_id: order.id
      )
    rescue StandardError => e
      raise CannotCreateFlow, e.message
    end

    # Checks if you have necessary funds for the amount you want to execute in the order.
    #   If BuyOpeningFlow, they must be in relation to the amounts and crypto funds.
    #   If SellOpeningFlow, they must be in relation to the amounts and fiat funds.
    #
    # @param[BigDecimal] balance. Funds of the species corresponding to the Flow you wish to open.
    # @param [BigDecimal] amount. Order size to open.
    #
    # @return [Booolean]
    def self.enough_funds?(funds, amount)
      funds >= amount
    end

    # Calculates the size of the order and its best price in relation to the order size configured for the purchase and
    # for the sale and with taker market information.
    #
    # @param [BigDecimal] taker_balance. Its represent available amountn on crypto/fiat.
    # @param [BigDecimal] maker_fee.
    # @param [BigDecimal] taker_fee.
    # @param [Array<ApiWrapper::Order>] taker_orders. List of taker bids/asks.
    # @param [Array<ApiWrapper::Transaction>] taker_orders. List of taker transactions.
    #
    # @return [Array[BigDecimal, BigDecimal]]
    def self.calc_taker_amount(taker_balance, maker_fee, taker_fee, taker_orders, taker_transactions)
      value_to_use_needed = (value_to_use + maker_plus(maker_fee)) / (1 - taker_fee / 100)
      price = safest_price(taker_transactions, taker_orders, value_to_use_needed)
      amount = remote_value_to_use(value_to_use_needed, price)

      Robot.log(
        :info,
        "Opening: Need #{taker_specie_to_spend} #{amount.truncate(8)} on #{Robot.taker.name} taker,"\
        " has #{taker_balance.truncate(8)}."
      )

      unless enough_funds?(taker_balance, amount)
        raise CannotCreateFlow,
              "Needed #{amount.truncate(8)}"\
              " but you only have #{taker_specie_to_spend} #{taker_balance.truncate(8)} on your taker market."
      end

      [amount, price]
    end

    def self.maker_plus(fee)
      value_to_use * fee / 100
    end

    # Buys on bitex represent open positions, we mirror them locally so that we can plan on how to close them.
    def self.sync_positions
      threshold = open_position_class.last.try(:created_at)

      Robot.maker.trades.map do |trade|
        # TODO cual es el caso en el que encuentro un trade que no tiene una posicion abierta?
        next unless sought_transaction?(trade, threshold)

        # TODO cual es el caso en el que encuentro un trade que no tiene una posicion abierta y ademas no tiene un opening flow?
        flow = find_by_order_id(trade.order_id)
        next unless flow.present?

        open_position_class.create!(
          transaction_id: trade.order_id, price: trade.price, amount: trade.fiat, quantity: trade.crypto, opening_flow: flow
        )
      end.compact
    end

    def self.create_open_position!(trade, flow)
    end

    # @param [ApiWrapper::UserTransaction] trade.
    # @param [Time] threshold.
    #
    # @return [Boolean]
    def self.sought_transaction?(trade, threshold)
      expected_kind_trade?(trade) && !active_trade?(trade, threshold) && !syncronized?(trade) && expected_orderbook?(trade)
    end

    # @param [ApiWrapper::UserTransaction] trade.
    # @param [Time] threshold.
    #
    # @return [Boolean]
    def self.active_trade?(trade, threshold)
      threshold.present? && trade.timestamp < (threshold - 30.minutes).to_i
    end

    # @param [ApiWrapper::UserTransaction] trade.
    #
    # @return [Boolean]
    def self.syncronized?(trade)
      open_position_class.find_by_transaction_id(trade.order_id).present?
    end

    # @param [ApiWrapper::UserTransaction] trade.
    #
    # @return [Boolean]
    def self.expected_orderbook?(trade)
      trade.raw.orderbook_code.to_s == Robot.maker.base_quote
    end

    validates :status, presence: true, inclusion: { in: statuses }
    validates :order_id, presence: true
    validates_presence_of :price, :value_to_use

    # Statuses:
    #   executing: The Bitex order has been placed, its id stored as order_id.
    #   settling: In process of cancelling the Bitex order and any other outstanding order in the other exchange.
    #   finalised: Successfully settled or finished executing.
    statuses.each do |status_name|
      define_method("#{status_name}?") { status == status_name }
      define_method("#{status_name}!") { update!(status: status_name) }
    end

    def finalise!
      # make api wrapper order status inquirable
      return finalised! if order.status == :cancelled || order.status == :completed

      Robot.maker.cancel_order(order)
      settling! unless settling?
    end

    private

   # TODO standarize about get orders with status, this is empotred as bitex order
    def order
      @order ||= Robot.with_cooldown do
        find_maker_order(order_id)
      end
    end
  end

  class CannotCreateFlow < StandardError; end
end

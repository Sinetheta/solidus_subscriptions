# This class takes a collection of installments and populates a new spree
# order with the correct contents based on the subscriptions associated to the
# intallments. This is to group together subscriptions being
# processed on the same day for a specific user
module SolidusSubscriptions
  class ConsolidatedInstallment
    # @return [Array<Installment>] The collection of installments to be used
    #   when generating a new order
    attr_reader :installments

    delegate :user, :root_order, to: :subscription

    # Get a new instance of a ConsolidatedInstallment
    #
    # @param installments [Array<Installment>] The collection of installments
    # to be used when generating a new order
    def initialize(installments)
      @installments = installments
      raise UserMismatchError.new(installments) if different_owners?
    end

    # Generate a new Spree::Order based on the information associated to the
    # installments
    #
    # @return [Spree::Order]
    def process
      populate

      # Installments are removed and set for future processing if they are
      # out of stock. If there are no line items left there is nothing to do
      return if installments.empty?

      if checkout
        Config.success_dispatcher_class.new(installments, order).dispatch
        return order
      end

      # A new order will only have 1 payment that we created
      if order.payments.any?(&:failed?)
        Config.payment_failed_dispatcher_class.new(installments, order).dispatch
        installments.clear
        nil
      end
    ensure
      # Any installments that failed to be processed will be reprocessed
      unfulfilled_installments = installments.select(&:unfulfilled?)
      if unfulfilled_installments.any?
        Config.failure_dispatcher_class.
          new(unfulfilled_installments, order).dispatch
      end
    end

    # The order fulfilling the consolidated installment
    #
    # @return [Spree::Order]
    def order
      @order ||= Spree::Order.create(
        user: user,
        email: user.email,
        store: root_order.try!(:store) || Spree::Store.default,
        subscription_order: true
      )
    end

    private

    def checkout
      order.update_totals
      apply_promotions

      order.next! # cart => address

      order.ship_address = ship_address
      order.next! # address => delivery
      order.next! # delivery => payment

      create_payment
      order.next! # payment => confirm

      # Do this as a separate "quiet" transition so that it returns true or
      # false rather than raising a failed transition error
      order.complete
    end

    def populate
      unfulfilled_installments = []

      line_items = installments.map do |installment|
        line_item = installment.line_item_builder.line_item

        if line_item.nil?
          unfulfilled_installments << installment
          next
        end

        line_item
      end.
      compact

      # Remove installments which had no stock from the active list
      # They will be reprocessed later
      @installments -= unfulfilled_installments
      if unfulfilled_installments.any?
        Config.out_of_stock_dispatcher_class.new(unfulfilled_installments).dispatch
      end

      return if installments.empty?
      order_builder.add_line_items(line_items)
    end

    def order_builder
      @order_builder ||= OrderBuilder.new(order)
    end

    def subscription
      installments.first.subscription
    end

    def ship_address
      user.ship_address || root_order.ship_address
    end

    def active_card
      user.credit_cards.default.last || root_order.credit_cards.last
    end

    def create_payment
      order.payments.create(
        source: active_card,
        amount: order.total,
        payment_method: Config.default_gateway
      )
    end

    def apply_promotions
      Spree::PromotionHandler::Cart.new(order).activate
      order.updater.update # reload totals
    end

    def different_owners?
      installments.map { |i| i.subscription.user }.uniq.length > 1
    end
  end
end

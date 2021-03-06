FactoryBot.define do
  factory :open_buy, class: BitexBot::OpenBuy do
    association :opening_flow, factory: :buy_opening_flow
    sequence(:id)

    transaction_id { 12_345_678 }
    price          { 300 }
    amount         { 600 }
    quantity       { 2 }
  end

  factory :tiny_open_buy, class: BitexBot::OpenBuy do
    association :opening_flow, factory: :other_buy_opening_flow
    sequence(:id)

    transaction_id { 23_456_789 }
    price          { 400 }
    amount         { 4 }
    quantity       { 0.01 }
  end

  factory :closing_open_buy, class: BitexBot::OpenBuy do
    association :opening_flow, factory: :buy_opening_flow
    association :closing_flow, factory: :buy_closing_flow
    sequence(:id)

    transaction_id { 23_456_789 }
    price          { 400 }
    amount         { 4 }
    quantity       { 0.01 }
  end
end

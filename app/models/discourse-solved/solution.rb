# frozen_string_literal: true

module ::DiscourseSolved
  class Solution < ActiveRecord::Base
    belongs_to :accepter, foreign_key: :accepter_user_id, class_name: :user
    belongs_to :post, foreign_key: :answer_post_id
    belongs_to :topic
    belongs_to :topic_timer, dependent: :destroy
  end
end

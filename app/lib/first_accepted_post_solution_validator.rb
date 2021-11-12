# frozen_string_literal: true

class FirstAcceptedPostSolutionValidator
  def self.check(post, trust_level:)
    return false if post.archetype != Archetype.default
    return false if !post&.user&.human?
    return true if trust_level == 'any'

    if TrustLevel.compare(post&.user&.trust_level, trust_level.to_i)
      return false
    end

    if !UserAction.where(user_id: post&.user_id, action_type: UserAction::SOLVED).exists?
      return true
    end

    false
  end
end

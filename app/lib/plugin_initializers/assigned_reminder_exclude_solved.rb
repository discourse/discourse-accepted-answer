# frozen_string_literal: true

module DiscourseSolved
  class PluginInitializer
    attr_reader :plugin

    def initialize(plugin)
      @plugin = plugin
    end

    def apply_plugin_api
      # this method should be overridden by subclasses
      raise NotImplementedError
    end
  end

  class AssignsReminderForTopicsQuery < PluginInitializer
    def apply_plugin_api
      plugin.register_modifier(:assigns_reminder_assigned_topics_query) do |query|
        next query if !SiteSetting.ignore_solved_topics_in_assigned_reminder
        query.where.not(id: DiscourseSolved::Solution.select(:topic_id))
      end
    end
  end

  class AssignedCountForUserQuery < PluginInitializer
    def apply_plugin_api
      plugin.register_modifier(:assigned_count_for_user_query) do |query, user|
        next query if !SiteSetting.ignore_solved_topics_in_assigned_reminder
        next query if SiteSetting.assignment_status_on_solve.blank?
        query.where.not(status: SiteSetting.assignment_status_on_solve)
      end
    end
  end
end

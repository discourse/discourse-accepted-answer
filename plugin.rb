# frozen_string_literal: true

# name: discourse-solved
# about: Allows users to accept solutions on topics in designated categories.
# meta_topic_id: 30155
# version: 0.1
# authors: Sam Saffron
# url: https://github.com/discourse/discourse-solved

enabled_site_setting :solved_enabled

register_svg_icon "far-square-check"
register_svg_icon "square-check"
register_svg_icon "far-square"

register_asset "stylesheets/solutions.scss"
register_asset "stylesheets/mobile/solutions.scss", :mobile

after_initialize do
  module ::DiscourseSolved
    PLUGIN_NAME = "discourse-solved"
    ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD = "accepted_answer_post_id"
    ENABLE_ACCEPTED_ANSWERS_CUSTOM_FIELD = "enable_accepted_answers"

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseSolved
    end
  end

  SeedFu.fixture_paths << Rails.root.join("plugins", "discourse-solved", "db", "fixtures").to_s

  require_relative "app/controllers/answer_controller"
  require_relative "app/lib/first_accepted_post_solution_validator"
  require_relative "app/lib/accepted_answer_cache"
  require_relative "app/lib/guardian_extensions"
  require_relative "app/lib/before_head_close"
  require_relative "app/lib/category_extension"
  require_relative "app/lib/post_serializer_extension"
  require_relative "app/lib/topic_posters_summary_extension"
  require_relative "app/lib/topic_view_serializer_extension"
  require_relative "app/lib/user_summary_extension"
  require_relative "app/lib/web_hook_extension"
  require_relative "app/serializers/concerns/topic_answer_mixin"
  require_relative "app/models/discourse-solved/solution.rb"

  require_relative "app/lib/plugin_initializers/assigned_reminder_exclude_solved"
  DiscourseSolved::AssignsReminderForTopicsQuery.new(self).apply_plugin_api
  DiscourseSolved::AssignedCountForUserQuery.new(self).apply_plugin_api
  module ::DiscourseSolved
    def self.accept_answer!(post, acting_user, topic: nil)
      topic ||= post.topic

      DistributedMutex.synchronize("discourse_solved_toggle_answer_#{topic.id}") do
        if topic.solution.present?
          UserAction.where(
            action_type: UserAction::SOLVED,
            target_post_id: topic.solution.answer_post_id,
          ).destroy_all
          topic.solution.destroy!
        end

        solution = DiscourseSolved::Solution.create(topic:, post:, accepter_user_id: acting_user.id)

        topic.custom_fields[ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD] = post.id

        UserAction.log_action!(
          action_type: UserAction::SOLVED,
          user_id: post.user_id,
          acting_user_id: acting_user.id,
          target_post_id: post.id,
          target_topic_id: post.topic_id,
        )

        notification_data = {
          message: "solved.accepted_notification",
          display_username: acting_user.username,
          topic_title: topic.title,
          title: "solved.notification.title",
        }.to_json

        unless acting_user.id == post.user_id
          Notification.create!(
            notification_type: Notification.types[:custom],
            user_id: post.user_id,
            topic_id: post.topic_id,
            post_number: post.post_number,
            data: notification_data,
          )
        end

        if SiteSetting.notify_on_staff_accept_solved && acting_user.id != topic.user_id
          Notification.create!(
            notification_type: Notification.types[:custom],
            user_id: topic.user_id,
            topic_id: post.topic_id,
            post_number: post.post_number,
            data: notification_data,
          )
        end

        auto_close_hours = 0
        if topic&.category.present?
          auto_close_hours = topic.category.custom_fields["solved_topics_auto_close_hours"].to_i
          auto_close_hours = 175_200 if auto_close_hours > 175_200 # 20 years
        end

        auto_close_hours = SiteSetting.solved_topics_auto_close_hours if auto_close_hours == 0

        if (auto_close_hours > 0) && !topic.closed
          topic_timer =
            topic.set_or_create_timer(
              TopicTimer.types[:silent_close],
              nil,
              based_on_last_post: true,
              duration_minutes: auto_close_hours * 60,
            )

          solution.topic_timer_id = topic_timer.id

          MessageBus.publish("/topic/#{topic.id}", reload_topic: true)
        end

        topic.save!
        solution.save!

        if WebHook.active_web_hooks(:accepted_solution).exists?
          payload = WebHook.generate_payload(:post, post)
          WebHook.enqueue_solved_hooks(:accepted_solution, post, payload)
        end

        DiscourseEvent.trigger(:accepted_solution, post)
      end
    end

    def self.unaccept_answer!(post, topic: nil)
      topic ||= post.topic
      topic ||= Topic.unscoped.find_by(id: post.topic_id)

      return if topic.nil?

      DistributedMutex.synchronize("discourse_solved_toggle_answer_#{topic.id}") do
        topic.solution&.destroy!
        topic.custom_fields.delete(ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD)

        topic.save!

        # TODO remove_action! does not allow for this type of interface
        UserAction.where(action_type: UserAction::SOLVED, target_post_id: post.id).destroy_all

        # yank notification
        notification =
          Notification.find_by(
            notification_type: Notification.types[:custom],
            user_id: post.user_id,
            topic_id: post.topic_id,
            post_number: post.post_number,
          )

        notification.destroy! if notification

        if WebHook.active_web_hooks(:unaccepted_solution).exists?
          payload = WebHook.generate_payload(:post, post)
          WebHook.enqueue_solved_hooks(:unaccepted_solution, post, payload)
        end

        DiscourseEvent.trigger(:unaccepted_solution, post)
      end
    end

    def self.skip_db?
      defined?(GlobalSetting.skip_db?) && GlobalSetting.skip_db?
    end
  end

  reloadable_patch do |plugin|
    ::Guardian.prepend(DiscourseSolved::GuardianExtensions)
    ::WebHook.prepend(DiscourseSolved::WebHookExtension)
    ::TopicViewSerializer.prepend(DiscourseSolved::TopicViewSerializerExtension)
    ::Category.prepend(DiscourseSolved::CategoryExtension)
    ::PostSerializer.prepend(DiscourseSolved::PostSerializerExtension)
    ::UserSummary.prepend(DiscourseSolved::UserSummaryExtension)
    ::Topic.attr_accessor(:accepted_answer_user_id)
    ::Topic.has_one(:solution, class_name: ::DiscourseSolved::Solution.to_s)
    ::Post.has_one(
      :solution,
      class_name: ::DiscourseSolved::Solution.to_s,
      foreign_key: :answer_post_id,
    )
    ::TopicPostersSummary.alias_method(:old_user_ids, :user_ids)
    ::TopicPostersSummary.prepend(DiscourseSolved::TopicPostersSummaryExtension)
    [
      ::TopicListItemSerializer,
      ::SearchTopicListItemSerializer,
      ::SuggestedTopicSerializer,
      ::UserSummarySerializer::TopicSerializer,
      ::ListableTopicSerializer,
    ].each { |klass| klass.include(TopicAnswerMixin) }
  end

  # we got to do a one time upgrade
  if !::DiscourseSolved.skip_db?
    unless Discourse.redis.get("solved_already_upgraded")
      unless UserAction.where(action_type: UserAction::SOLVED).exists?
        Rails.logger.info("Upgrading storage for solved")
        sql = <<~SQL
          INSERT INTO user_actions(action_type,
                                   user_id,
                                   target_topic_id,
                                   target_post_id,
                                   acting_user_id,
                                   created_at,
                                   updated_at)
          SELECT :solved,
                 p.user_id,
                 p.topic_id,
                 p.id,
                 t.user_id,
                 pc.created_at,
                 pc.updated_at
          FROM
            post_custom_fields pc
          JOIN
            posts p ON p.id = pc.post_id
          JOIN
            topics t ON t.id = p.topic_id
          WHERE
            pc.name = 'is_accepted_answer' AND
            pc.value = 'true' AND
            p.user_id IS NOT NULL
        SQL

        DB.exec(sql, solved: UserAction::SOLVED)
      end
      Discourse.redis.set("solved_already_upgraded", "true")
    end
  end

  DiscourseSolved::Engine.routes.draw do
    post "/accept" => "answer#accept"
    post "/unaccept" => "answer#unaccept"
  end

  Discourse::Application.routes.append { mount ::DiscourseSolved::Engine, at: "solution" }

  on(:post_destroyed) { |post| ::DiscourseSolved.unaccept_answer!(post) if post.solution }

  add_api_key_scope(
    :solved,
    { answer: { actions: %w[discourse_solved/answer#accept discourse_solved/answer#unaccept] } },
  )

  register_html_builder("server:before-head-close-crawler") do |controller|
    DiscourseSolved::BeforeHeadClose.new(controller).html
  end

  register_html_builder("server:before-head-close") do |controller|
    DiscourseSolved::BeforeHeadClose.new(controller).html
  end

  Report.add_report("accepted_solutions") do |report|
    report.data = []

    accepted_solutions = DiscourseSolved::Solution

    category_id, include_subcategories = report.add_category_filter
    if category_id
      if include_subcategories
        accepted_solutions =
          accepted_solutions.joins(:topic).where(
            "topics.category_id IN (?)",
            Category.subcategory_ids(category_id),
          )
      else
        accepted_solutions =
          accepted_solutions.joins(:topic).where("topics.category_id = ?", category_id)
      end
    end

    accepted_solutions
      .where("discourse_solved_solutions.created_at >= ?", report.start_date)
      .where("discourse_solved_solutions.created_at <= ?", report.end_date)
      .group("DATE(discourse_solved_solutions.created_at)")
      .order("DATE(discourse_solved_solutions.created_at)")
      .count
      .each { |date, count| report.data << { x: date, y: count } }
    report.total = accepted_solutions.count
    report.prev30Days =
      accepted_solutions
        .where("discourse_solved_solutions.created_at >= ?", report.start_date - 30.days)
        .where("discourse_solved_solutions.created_at <= ?", report.start_date)
        .count
  end

  register_modifier(:search_rank_sort_priorities) do |priorities, _search|
    if SiteSetting.prioritize_solved_topics_in_search
      condition = <<~SQL
          EXISTS (
            SELECT 1
              FROM discourse_solved_solutions
             WHERE topic_id = topics.id
          )
        SQL

      priorities.push([condition, 1.1])
    else
      priorities
    end
  end

  add_to_serializer(:user_summary, :solved_count) { object.solved_count }
  add_to_serializer(:post, :can_accept_answer) do
    scope.can_accept_answer?(topic, object) && object.post_number > 1 && !accepted_answer
  end
  add_to_serializer(:post, :can_unaccept_answer) do
    scope.can_accept_answer?(topic, object) && accepted_answer
  end
  add_to_serializer(:post, :accepted_answer) do
    if topic&.custom_fields&.[](::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD).nil?
      return false
    end
    topic.solution.answer_post_id == object.id
  end
  add_to_serializer(:post, :topic_accepted_answer) do
    topic&.custom_fields&.[](::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD).present?
  end

  solved_callback = ->(scope) do
    sql = <<~SQL
      topics.id IN (
        SELECT topic_id
          FROM topic_custom_fields
         WHERE name = '#{::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD}'
           AND value IS NOT NULL
      )
    SQL

    scope.where(sql)
  end

  unsolved_callback = ->(scope) do
    scope = scope.where <<~SQL
      topics.id NOT IN (
        SELECT topic_id
          FROM topic_custom_fields
         WHERE name = '#{::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD}'
           AND value IS NOT NULL
      )
    SQL

    if !SiteSetting.allow_solved_on_all_topics
      tag_ids = Tag.where(name: SiteSetting.enable_solved_tags.split("|")).pluck(:id)

      scope = scope.where <<~SQL, tag_ids
        topics.id IN (
          SELECT t.id
            FROM topics t
            JOIN category_custom_fields cc
              ON t.category_id = cc.category_id
             AND cc.name = '#{::DiscourseSolved::ENABLE_ACCEPTED_ANSWERS_CUSTOM_FIELD}'
             AND cc.value = 'true'
        )
        OR
        topics.id IN (
          SELECT topic_id
            FROM topic_tags
           WHERE tag_id IN (?)
        )
      SQL
    end

    scope
  end

  register_custom_filter_by_status("solved", &solved_callback)
  register_custom_filter_by_status("unsolved", &unsolved_callback)

  register_search_advanced_filter(/status:solved/, &solved_callback)
  register_search_advanced_filter(/status:unsolved/, &unsolved_callback)

  TopicQuery.add_custom_filter(:solved) do |results, topic_query|
    if topic_query.options[:solved] == "yes"
      solved_callback.call(results)
    elsif topic_query.options[:solved] == "no"
      unsolved_callback.call(results)
    else
      results
    end
  end

  TopicList.preloaded_custom_fields << ::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD
  Site.preloaded_category_custom_fields << ::DiscourseSolved::ENABLE_ACCEPTED_ANSWERS_CUSTOM_FIELD
  Search.preloaded_topic_custom_fields << ::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD
  CategoryList.preloaded_topic_custom_fields << ::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD

  on(:filter_auto_bump_topics) do |_category, filters|
    filters.push(
      ->(r) do
        sql = <<~SQL
          NOT EXISTS (
            SELECT 1
              FROM discourse_solved_solutions
             WHERE topic_id = topics.id
          )
        SQL

        r.where(sql)
      end,
    )
  end

  on(:before_post_publish_changes) do |post_changes, topic_changes, options|
    category_id_changes = topic_changes.diff["category_id"].to_a
    tag_changes = topic_changes.diff["tags"].to_a

    old_allowed = Guardian.new.allow_accepted_answers?(category_id_changes[0], tag_changes[0])
    new_allowed = Guardian.new.allow_accepted_answers?(category_id_changes[1], tag_changes[1])

    options[:refresh_stream] = true if old_allowed != new_allowed
  end

  on(:after_populate_dev_records) do |records, type|
    next unless SiteSetting.solved_enabled

    if type == :category
      next if SiteSetting.allow_solved_on_all_topics

      solved_category =
        DiscourseDev::Record.random(
          Category.where(read_restricted: false, id: records.pluck(:id), parent_category_id: nil),
        )
      CategoryCustomField.create!(
        category_id: solved_category.id,
        name: ::DiscourseSolved::ENABLE_ACCEPTED_ANSWERS_CUSTOM_FIELD,
        value: "true",
      )
      puts "discourse-solved enabled on category '#{solved_category.name}' (#{solved_category.id})."
    elsif type == :topic
      topics = Topic.where(id: records.pluck(:id))

      unless SiteSetting.allow_solved_on_all_topics
        solved_category_id =
          CategoryCustomField
            .where(name: ::DiscourseSolved::ENABLE_ACCEPTED_ANSWERS_CUSTOM_FIELD, value: "true")
            .first
            .category_id

        unless topics.exists?(category_id: solved_category_id)
          topics.last.update(category_id: solved_category_id)
        end

        topics = topics.where(category_id: solved_category_id)
      end

      solved_topic = DiscourseDev::Record.random(topics)
      post = nil

      if solved_topic.posts_count > 1
        post = DiscourseDev::Record.random(solved_topic.posts.where.not(post_number: 1))
      else
        post = DiscourseDev::Post.new(solved_topic, 1).create!
      end

      DiscourseSolved.accept_answer!(post, post.topic.user, topic: post.topic)
    end
  end

  query =
    "
    WITH x AS (SELECT
      u.id user_id,
      COUNT(DISTINCT ua.id) AS solutions
      FROM users AS u
      LEFT OUTER JOIN user_actions AS ua ON ua.user_id = u.id AND ua.action_type = #{UserAction::SOLVED} AND COALESCE(ua.created_at, :since) > :since
      WHERE u.active
        AND u.silenced_till IS NULL
        AND u.id > 0
      GROUP BY u.id
    )
    UPDATE directory_items di SET
      solutions = x.solutions
    FROM x
    WHERE x.user_id = di.user_id
    AND di.period_type = :period_type
    AND di.solutions <> x.solutions
  "
  add_directory_column("solutions", query: query)

  add_to_class(:composer_messages_finder, :check_topic_is_solved) do
    return if !SiteSetting.solved_enabled || SiteSetting.disable_solved_education_message
    return if !replying? || @topic.blank? || @topic.private_message?
    return if @topic.custom_fields[::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD].blank?

    {
      id: "solved_topic",
      templateName: "education",
      wait_for_typing: true,
      extraClass: "education-message",
      hide_if_whisper: true,
      body: PrettyText.cook(I18n.t("education.topic_is_solved", base_url: Discourse.base_url)),
    }
  end

  add_to_serializer(:user_card, :accepted_answers) do
    UserAction.where(user_id: object.id).where(action_type: UserAction::SOLVED).count
  end

  register_topic_list_preload_user_ids do |topics, user_ids, topic_list|
    answer_post_ids =
      TopicCustomField
        .select("value::INTEGER")
        .where(name: ::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD)
        .where(topic_id: topics.map(&:id))
    answer_user_ids = Post.where(id: answer_post_ids).pluck(:topic_id, :user_id).to_h
    topics.each { |topic| topic.accepted_answer_user_id = answer_user_ids[topic.id] }
    user_ids.concat(answer_user_ids.values)
  end

  if defined?(DiscourseAutomation)
    on(:accepted_solution) do |post|
      # testing directly automation is prone to issues
      # we prefer to abstract logic in service object and test this
      next if Rails.env.test?

      name = "first_accepted_solution"
      DiscourseAutomation::Automation
        .where(trigger: name, enabled: true)
        .find_each do |automation|
          maximum_trust_level = automation.trigger_field("maximum_trust_level")&.dig("value")
          if FirstAcceptedPostSolutionValidator.check(post, trust_level: maximum_trust_level)
            automation.trigger!(
              "kind" => name,
              "accepted_post_id" => post.id,
              "usernames" => [post.user.username],
              "placeholders" => {
                "post_url" => Discourse.base_url + post.url,
              },
            )
          end
        end
    end

    add_triggerable_to_scriptable(:first_accepted_solution, :send_pms)

    DiscourseAutomation::Triggerable.add(:first_accepted_solution) do
      placeholder :post_url

      field :maximum_trust_level,
            component: :choices,
            extra: {
              content: [
                {
                  id: 1,
                  name:
                    "discourse_automation.triggerables.first_accepted_solution.max_trust_level.tl1",
                },
                {
                  id: 2,
                  name:
                    "discourse_automation.triggerables.first_accepted_solution.max_trust_level.tl2",
                },
                {
                  id: 3,
                  name:
                    "discourse_automation.triggerables.first_accepted_solution.max_trust_level.tl3",
                },
                {
                  id: 4,
                  name:
                    "discourse_automation.triggerables.first_accepted_solution.max_trust_level.tl4",
                },
                {
                  id: "any",
                  name:
                    "discourse_automation.triggerables.first_accepted_solution.max_trust_level.any",
                },
              ],
            },
            required: true
    end
  end

  if defined?(DiscourseAssign)
    on(:accepted_solution) do |post|
      next if SiteSetting.assignment_status_on_solve.blank?
      assignments = Assignment.includes(:target).where(topic: post.topic)
      assignments.each do |assignment|
        assigned_user = User.find_by(id: assignment.assigned_to_id)
        Assigner.new(assignment.target, assigned_user).assign(
          assigned_user,
          status: SiteSetting.assignment_status_on_solve,
        )
      end
    end
    on(:unaccepted_solution) do |post|
      next if SiteSetting.assignment_status_on_unsolve.blank?
      assignments = Assignment.includes(:target).where(topic: post.topic)
      assignments.each do |assignment|
        assigned_user = User.find_by(id: assignment.assigned_to_id)
        Assigner.new(assignment.target, assigned_user).assign(
          assigned_user,
          status: SiteSetting.assignment_status_on_unsolve,
        )
      end
    end
  end
end

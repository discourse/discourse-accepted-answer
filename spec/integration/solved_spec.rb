# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Managing Posts solved status" do
  let(:topic) { Fabricate(:topic) }
  fab!(:user) { Fabricate(:trust_level_4) }
  let(:p1) { Fabricate(:post, topic: topic) }

  before { SiteSetting.allow_solved_on_all_topics = true }

  describe "customer filters" do
    before do
      SiteSetting.allow_solved_on_all_topics = false
      SiteSetting.enable_solved_tags = solvable_tag.name
    end

    fab!(:solvable_category) do
      category = Fabricate(:category)

      CategoryCustomField.create(
        category_id: category.id,
        name: ::DiscourseSolved::ENABLE_ACCEPTED_ANSWERS_CUSTOM_FIELD,
        value: "true",
      )

      category
    end

    fab!(:solvable_tag) { Fabricate(:tag) }

    fab!(:solved_in_category) do
      Fabricate(
        :custom_topic,
        category: solvable_category,
        custom_topic_name: ::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD,
        value: "42",
      )
    end

    fab!(:solved_in_tag) do
      Fabricate(
        :custom_topic,
        tags: [solvable_tag],
        custom_topic_name: ::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD,
        value: "42",
      )
    end

    fab!(:unsolved_in_category) { Fabricate(:topic, category: solvable_category) }
    fab!(:unsolved_in_tag) { Fabricate(:topic, tags: [solvable_tag]) }

    fab!(:unsolved_topic) { Fabricate(:topic) }

    it "can filter by solved status" do
      expect(
        TopicsFilter
          .new(guardian: Guardian.new)
          .filter_from_query_string("status:solved")
          .pluck(:id),
      ).to contain_exactly(solved_in_category.id, solved_in_tag.id)
    end

    it "can filter by unsolved status" do
      expect(
        TopicsFilter
          .new(guardian: Guardian.new)
          .filter_from_query_string("status:unsolved")
          .pluck(:id),
      ).to contain_exactly(unsolved_in_category.id, unsolved_in_tag.id)
    end
  end

  describe "search" do
    before { SearchIndexer.enable }

    after { SearchIndexer.disable }

    it "can prioritize solved topics in search" do
      normal_post =
        Fabricate(
          :post,
          raw: "My reply carrot",
          topic: Fabricate(:topic, title: "A topic that is not solved but open"),
        )

      solved_post =
        Fabricate(
          :post,
          raw: "My solution carrot",
          topic: Fabricate(:topic, title: "A topic that will be closed", closed: true),
        )

      DiscourseSolved.accept_answer!(solved_post, Discourse.system_user)

      result = Search.execute("carrot")
      expect(result.posts.pluck(:id)).to eq([normal_post.id, solved_post.id])

      SiteSetting.prioritize_solved_topics_in_search = true

      result = Search.execute("carrot")
      expect(result.posts.pluck(:id)).to eq([solved_post.id, normal_post.id])
    end

    describe "#advanced_search" do
      fab!(:category_enabled) do
        category = Fabricate(:category)
        category_custom_field =
          CategoryCustomField.new(
            category_id: category.id,
            name: ::DiscourseSolved::ENABLE_ACCEPTED_ANSWERS_CUSTOM_FIELD,
            value: "true",
          )
        category_custom_field.save
        category
      end
      fab!(:category_disabled) do
        category = Fabricate(:category)
        category_custom_field =
          CategoryCustomField.new(
            category_id: category.id,
            name: ::DiscourseSolved::ENABLE_ACCEPTED_ANSWERS_CUSTOM_FIELD,
            value: "false",
          )
        category_custom_field.save
        category
      end
      fab!(:tag)
      fab!(:topic_unsolved) do
        Fabricate(
          :custom_topic,
          user: user,
          category: category_enabled,
          custom_topic_name: ::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD,
        )
      end
      fab!(:topic_unsolved_2) { Fabricate(:topic, user: user, tags: [tag]) }
      fab!(:topic_solved) do
        Fabricate(
          :custom_topic,
          user: user,
          category: category_enabled,
          custom_topic_name: ::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD,
        )
      end
      fab!(:topic_disabled_1) do
        Fabricate(
          :custom_topic,
          user: user,
          category: category_disabled,
          custom_topic_name: ::DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD,
        )
      end
      fab!(:topic_disabled_2) do
        Fabricate(
          :custom_topic,
          user: user,
          category: category_disabled,
          custom_topic_name: "another_custom_field",
        )
      end
      fab!(:post_unsolved) { Fabricate(:post, topic: topic_unsolved) }
      fab!(:post_unsolved_2) { Fabricate(:post, topic: topic_unsolved_2) }
      fab!(:post_solved) do
        post = Fabricate(:post, topic: topic_solved)
        DiscourseSolved.accept_answer!(post, Discourse.system_user)
        post
      end
      fab!(:post_disabled_1) { Fabricate(:post, topic: topic_disabled_1) }
      fab!(:post_disabled_2) { Fabricate(:post, topic: topic_disabled_2) }

      before do
        SiteSetting.enable_solved_tags = tag.name
        SearchIndexer.enable
        Jobs.run_immediately!

        SearchIndexer.index(topic_unsolved, force: true)
        SearchIndexer.index(topic_unsolved_2, force: true)
        SearchIndexer.index(topic_solved, force: true)
        SearchIndexer.index(topic_disabled_1, force: true)
        SearchIndexer.index(topic_disabled_2, force: true)
      end

      after { SearchIndexer.disable }

      describe "searches for unsolved topics" do
        describe "when allow solved on all topics is disabled" do
          before { SiteSetting.allow_solved_on_all_topics = false }

          it "only returns unsolved posts from categories and tags where solving is enabled" do
            result = Search.execute("status:unsolved")
            expect(result.posts.pluck(:id)).to match_array([post_unsolved.id, post_unsolved_2.id])
          end

          it "returns the filtered results when combining search with a tag" do
            result = Search.execute("status:unsolved tag:#{tag.name}")
            expect(result.posts.pluck(:id)).to match_array([post_unsolved_2.id])
          end
        end

        describe "when allow solved on all topics is enabled" do
          before { SiteSetting.allow_solved_on_all_topics = true }
          it "only returns posts where the post is not solved" do
            result = Search.execute("status:unsolved")
            expect(result.posts.pluck(:id)).to match_array(
              [post_unsolved.id, post_unsolved_2.id, post_disabled_1.id, post_disabled_2.id],
            )
          end
        end
      end
    end
  end

  describe "auto bump" do
    it "does not automatically bump solved topics" do
      category = Fabricate(:category_with_definition)

      post = create_post(category: category)
      post2 = create_post(category: category)

      DiscourseSolved.accept_answer!(post, Discourse.system_user)

      category.num_auto_bump_daily = 2
      category.save!

      freeze_time 1.month.from_now

      expect(category.auto_bump_topic!).to eq(true)

      freeze_time 13.hours.from_now

      expect(category.auto_bump_topic!).to eq(false)

      expect(post.topic.reload.posts_count).to eq(1)
      expect(post2.topic.reload.posts_count).to eq(2)
    end
  end

  describe "accepting a post as the answer" do
    before do
      sign_in(user)
      SiteSetting.solved_topics_auto_close_hours = 2
    end

    it "can mark a post as the accepted answer correctly" do
      freeze_time

      post "/solution/accept.json", params: { id: p1.id }

      expect(response.status).to eq(200)
      expect(p1.reload.solution.present?).to eq(true)

      topic.reload

      expect(topic.public_topic_timer.status_type).to eq(TopicTimer.types[:silent_close])

      expect(topic.solution.topic_timer_id).to eq(topic.public_topic_timer.id)

      expect(topic.public_topic_timer.execute_at).to eq_time(Time.zone.now + 2.hours)

      expect(topic.public_topic_timer.based_on_last_post).to eq(true)
    end

    it "gives priority to category's solved_topics_auto_close_hours setting" do
      freeze_time
      custom_auto_close_category = Fabricate(:category)
      topic_2 = Fabricate(:topic, category: custom_auto_close_category)
      post_2 = Fabricate(:post, topic: topic_2)
      custom_auto_close_category.custom_fields["solved_topics_auto_close_hours"] = 4
      custom_auto_close_category.save_custom_fields

      post "/solution/accept.json", params: { id: post_2.id }

      expect(response.status).to eq(200)
      expect(post_2.reload.solution.present?).to eq(true)

      topic_2.reload

      expect(topic_2.public_topic_timer.status_type).to eq(TopicTimer.types[:silent_close])

      expect(topic_2.solution.topic_timer_id).to eq(topic_2.public_topic_timer.id)

      expect(topic_2.public_topic_timer.execute_at).to eq_time(Time.zone.now + 4.hours)

      expect(topic_2.public_topic_timer.based_on_last_post).to eq(true)
    end

    it "sends notifications to correct users" do
      SiteSetting.notify_on_staff_accept_solved = true
      user = Fabricate(:user)
      topic = Fabricate(:topic, user: user)
      post = Fabricate(:post, post_number: 2, topic: topic)

      op = topic.user
      user = post.user

      expect { DiscourseSolved.accept_answer!(post, Discourse.system_user) }.to change {
        user.notifications.count
      }.by(1) & change { op.notifications.count }.by(1)

      notification = user.notifications.last
      expect(notification.notification_type).to eq(Notification.types[:custom])
      expect(notification.topic_id).to eq(post.topic_id)
      expect(notification.post_number).to eq(post.post_number)

      notification = op.notifications.last
      expect(notification.notification_type).to eq(Notification.types[:custom])
      expect(notification.topic_id).to eq(post.topic_id)
      expect(notification.post_number).to eq(post.post_number)
    end

    it "does not set a timer when the topic is closed" do
      topic.update!(closed: true)
      post "/solution/accept.json", params: { id: p1.id }

      expect(response.status).to eq(200)

      p1.reload
      topic.reload

      expect(p1.solution.present?).to eq(true)
      expect(topic.public_topic_timer).to eq(nil)
      expect(topic.closed).to eq(true)
    end

    it "works with staff and trashed topics" do
      topic.trash!(Discourse.system_user)

      post "/solution/accept.json", params: { id: p1.id }
      expect(response.status).to eq(403)

      sign_in(Fabricate(:admin))
      post "/solution/accept.json", params: { id: p1.id }
      expect(response.status).to eq(200)

      p1.reload
      expect(p1.solution.present?).to eq(true)
    end

    it "removes the solution when the post is deleted" do
      reply = Fabricate(:post, post_number: 2, topic: topic)

      post "/solution/accept.json", params: { id: reply.id }
      expect(response.status).to eq(200)

      reply.reload
      expect(reply.solution.present?).to eq(true)
      expect(reply.topic.custom_fields["accepted_answer_post_id"].to_i).to eq(reply.id)

      PostDestroyer.new(Discourse.system_user, reply).destroy

      reply.reload
      expect(reply.solution).to eq(nil)
      expect(reply.topic.custom_fields["accepted_answer_post_id"]).to eq(nil)
    end

    it "does not allow you to accept a whisper" do
      whisper = Fabricate(:post, topic: topic, post_type: Post.types[:whisper])
      sign_in(Fabricate(:admin))

      post "/solution/accept.json", params: { id: whisper.id }
      expect(response.status).to eq(403)
    end

    it "triggers a webhook" do
      Fabricate(:solved_web_hook)
      post "/solution/accept.json", params: { id: p1.id }

      job_args = Jobs::EmitWebHookEvent.jobs[0]["args"].first

      expect(job_args["event_name"]).to eq("accepted_solution")
      payload = JSON.parse(job_args["payload"])
      expect(payload["id"]).to eq(p1.id)
    end
  end

  describe "#unaccept" do
    before { sign_in(user) }

    describe "when solved_topics_auto_close_hours is enabled" do
      before do
        SiteSetting.solved_topics_auto_close_hours = 2
        DiscourseSolved.accept_answer!(p1, user)
      end

      it "should unmark the post as solved" do
        expect do post "/solution/unaccept.json", params: { id: p1.id } end.to change {
          topic.reload.public_topic_timer
        }.to(nil)

        expect(response.status).to eq(200)
        p1.reload

        expect(p1.solution).to eq(nil)
        expect(p1.topic.custom_fields["accepted_answer_post_id"]).to eq(nil)
      end
    end

    it "triggers a webhook" do
      Fabricate(:solved_web_hook)
      post "/solution/unaccept.json", params: { id: p1.id }

      job_args = Jobs::EmitWebHookEvent.jobs[0]["args"].first

      expect(job_args["event_name"]).to eq("unaccepted_solution")
      payload = JSON.parse(job_args["payload"])
      expect(payload["id"]).to eq(p1.id)
    end
  end

  context "with group moderators" do
    fab!(:group_user)
    let!(:category_moderation_group) do
      Fabricate(:category_moderation_group, category: p1.topic.category, group: group_user.group)
    end
    let(:user_gm) { group_user.user }

    before do
      SiteSetting.enable_category_group_moderation = true
      sign_in(user_gm)
    end

    it "can accept a solution" do
      post "/solution/accept.json", params: { id: p1.id }
      expect(response.status).to eq(200)
    end
  end

  context "with discourse-assign installed", if: defined?(DiscourseAssign) do
    let(:admin) { Fabricate(:admin) }
    fab!(:group)
    before do
      SiteSetting.solved_enabled = true
      SiteSetting.assign_enabled = true
      SiteSetting.enable_assign_status = true
      SiteSetting.assign_allowed_on_groups = "#{group.id}"
      SiteSetting.assigns_public = true
      SiteSetting.assignment_status_on_solve = "Done"
      SiteSetting.assignment_status_on_unsolve = "New"
      SiteSetting.ignore_solved_topics_in_assigned_reminder = false
      group.add(p1.acting_user)
      group.add(user)

      sign_in(user)
    end

    describe "updating assignment status on solve when assignment_status_on_solve is set" do
      it "update all assignments to this status when a post is accepted" do
        assigner = Assigner.new(p1.topic, user)
        result = assigner.assign(user)
        expect(result[:success]).to eq(true)

        expect(p1.topic.assignment.status).to eq("New")
        DiscourseSolved.accept_answer!(p1, user)

        expect(p1.reload.solution.present?).to eq(true)
        expect(p1.topic.assignment.reload.status).to eq("Done")
      end

      it "update all assignments to this status when a post is unaccepted" do
        assigner = Assigner.new(p1.topic, user)
        result = assigner.assign(user)
        expect(result[:success]).to eq(true)

        DiscourseSolved.accept_answer!(p1, user)

        expect(p1.reload.topic.assignment.reload.status).to eq("Done")

        DiscourseSolved.unaccept_answer!(p1)

        expect(p1.reload.solution).to eq(nil)
        expect(p1.reload.topic.assignment.reload.status).to eq("New")
      end

      it "does not update the assignee when a post is accepted" do
        user_1 = Fabricate(:user)
        user_2 = Fabricate(:user)
        user_3 = Fabricate(:user)
        group.add(user_1)
        group.add(user_2)
        group.add(user_3)

        topic_question = Fabricate(:topic, user: user_1)

        Fabricate(:post, topic: topic_question, user: user_1)
        Fabricate(:post, topic: topic_question, user: user_2)

        result = Assigner.new(topic_question, user_2).assign(user_2)
        expect(result[:success]).to eq(true)

        post_response = Fabricate(:post, topic: topic_question, user: user_3)
        Assigner.new(post_response, user_3).assign(user_3)

        DiscourseSolved.accept_answer!(post_response, user_1)

        expect(topic_question.assignment.assigned_to_id).to eq(user_2.id)
        expect(post_response.assignment.assigned_to_id).to eq(user_3.id)
        DiscourseSolved.unaccept_answer!(post_response)

        expect(topic_question.assignment.assigned_to_id).to eq(user_2.id)
        expect(post_response.assignment.assigned_to_id).to eq(user_3.id)
      end

      describe "assigned topic reminder" do
        it "excludes solved topics when ignore_solved_topics_in_assigned_reminder is false" do
          other_topic = Fabricate(:topic, title: "Topic that should be there")
          post = Fabricate(:post, topic: other_topic, user: user)

          other_topic2 = Fabricate(:topic, title: "Topic that should be there2")
          post2 = Fabricate(:post, topic: other_topic2, user: user)

          Assigner.new(post.topic, user).assign(user)
          Assigner.new(post2.topic, user).assign(user)

          reminder = PendingAssignsReminder.new
          topics = reminder.send(:assigned_topics, user, order: :asc)
          expect(topics.to_a.length).to eq(2)

          DiscourseSolved.accept_answer!(post2, Discourse.system_user)
          topics = reminder.send(:assigned_topics, user, order: :asc)
          expect(topics.to_a.length).to eq(2)
          expect(topics).to include(other_topic2)

          SiteSetting.ignore_solved_topics_in_assigned_reminder = true
          topics = reminder.send(:assigned_topics, user, order: :asc)
          expect(topics.to_a.length).to eq(1)
          expect(topics).not_to include(other_topic2)
          expect(topics).to include(other_topic)
        end
      end

      describe "assigned count for user" do
        it "does not count solved topics using assignment_status_on_solve status" do
          SiteSetting.ignore_solved_topics_in_assigned_reminder = true

          other_topic = Fabricate(:topic, title: "Topic that should be there")
          post = Fabricate(:post, topic: other_topic, user: user)

          other_topic2 = Fabricate(:topic, title: "Topic that should be there2")
          post2 = Fabricate(:post, topic: other_topic2, user: user)

          Assigner.new(post.topic, user).assign(user)
          Assigner.new(post2.topic, user).assign(user)

          reminder = PendingAssignsReminder.new
          expect(reminder.send(:assigned_count_for, user)).to eq(2)

          DiscourseSolved.accept_answer!(post2, Discourse.system_user)
          expect(reminder.send(:assigned_count_for, user)).to eq(1)
        end
      end
    end
  end

  describe "#unaccept_answer!" do
    it "works even when the topic has been deleted" do
      user = Fabricate(:user, trust_level: 1)
      topic = Fabricate(:topic, user:)
      reply = Fabricate(:post, topic:, user:, post_number: 2)

      DiscourseSolved.accept_answer!(reply, user)

      topic.trash!(Discourse.system_user)
      reply.reload

      expect(reply.topic).to eq(nil)

      expect { DiscourseSolved.unaccept_answer!(reply) }.not_to raise_error
    end
  end
end

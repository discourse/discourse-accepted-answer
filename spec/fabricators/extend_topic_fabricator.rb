# frozen_string_literal: true
Fabricator(:custom_topic, from: :topic) do
  transient :custom_topic_name
  transient :value
  after_create do |top, transients|
    if transients[:custom_topic_name] == DiscourseSolved::ACCEPTED_ANSWER_POST_ID_CUSTOM_FIELD
      post = Fabricate(:post)
      Fabricate(:solution, topic_id: top.id, answer_post_id: post.id)
    end
    custom_topic =
      TopicCustomField.new(
        topic_id: top.id,
        name: transients[:custom_topic_name],
        value: transients[:value],
      )
    custom_topic.save
  end
end

# frozen_string_literal: true

Fabricator(:solution, from: DiscourseSolved::Solution) do
  topic_id
  answer_post_id
end

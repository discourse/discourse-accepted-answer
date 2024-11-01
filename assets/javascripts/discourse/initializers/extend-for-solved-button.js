import { computed } from "@ember/object";
import {
  POST_MENU_ADMIN_BUTTON_KEY,
  POST_MENU_COPY_LINK_BUTTON_KEY,
  POST_MENU_DELETE_BUTTON_KEY,
  POST_MENU_LIKE_BUTTON_KEY,
  POST_MENU_SHARE_BUTTON_KEY,
  POST_MENU_SHOW_MORE_BUTTON_KEY,
} from "discourse/components/post/menu";
import TopicStatusIcons from "discourse/helpers/topic-status-icons";
import { withPluginApi } from "discourse/lib/plugin-api";
import { formatUsername } from "discourse/lib/utilities";
import Topic from "discourse/models/topic";
import User from "discourse/models/user";
import TopicStatus from "discourse/raw-views/topic-status";
import PostCooked from "discourse/widgets/post-cooked";
import { withSilencedDeprecations } from "discourse-common/lib/deprecated";
import { iconHTML, iconNode } from "discourse-common/lib/icon-library";
import I18n from "I18n";
import SolvedAcceptAnswerButton, {
  acceptAnswer,
} from "../components/solved-accept-answer-button";
import SolvedUnacceptAnswerButton, {
  unacceptAnswer,
} from "../components/solved-unaccept-answer-button";

function initializeWithApi(api) {
  customizePostMenu(api);

  TopicStatusIcons.addObject([
    "has_accepted_answer",
    "far-check-square",
    "solved",
  ]);

  api.includePostAttributes(
    "can_accept_answer",
    "can_unaccept_answer",
    "accepted_answer",
    "topic_accepted_answer"
  );

  if (api.addDiscoveryQueryParam) {
    api.addDiscoveryQueryParam("solved", { replace: true, refreshModel: true });
  }

  api.decorateWidget("post-contents:after-cooked", (dec) => {
    if (dec.attrs.post_number === 1) {
      const postModel = dec.getModel();
      if (postModel) {
        const topic = postModel.topic;
        if (topic.accepted_answer) {
          const hasExcerpt = !!topic.accepted_answer.excerpt;

          const withExcerpt = `
            <aside class='quote accepted-answer' data-post="${
              topic.get("accepted_answer").post_number
            }" data-topic="${topic.id}">
              <div class='title'>
                ${topic.acceptedAnswerHtml} <div class="quote-controls"><\/div>
              </div>
              <blockquote>
                ${topic.accepted_answer.excerpt}
              </blockquote>
            </aside>`;

          const withoutExcerpt = `
            <aside class='quote accepted-answer'>
              <div class='title title-only'>
                ${topic.acceptedAnswerHtml}
              </div>
            </aside>`;

          const cooked = new PostCooked(
            { cooked: hasExcerpt ? withExcerpt : withoutExcerpt },
            dec
          );
          return dec.rawHtml(cooked.init());
        }
      }
    }
  });

  api.attachWidgetAction("post", "acceptAnswer", function () {
    acceptAnswer(this.model, this.appEvents);
  });

  api.attachWidgetAction("post", "unacceptAnswer", function () {
    unacceptAnswer(this.model, this.appEvents);
  });
}

function customizePostMenu(api) {
  const transformerRegistered = api.registerValueTransformer(
    "post-menu-buttons",
    ({ value: dag, context: { post } }) => {
      let solvedButton;

      if (post.can_accept_answer) {
        solvedButton = SolvedAcceptAnswerButton;
      } else if (post.accepted_answer) {
        solvedButton = SolvedUnacceptAnswerButton;
      }

      solvedButton &&
        dag.add(
          "solved",
          solvedButton,
          post.topic_accepted_answer && !post.accepted_answer
            ? {
                before: [
                  POST_MENU_ADMIN_BUTTON_KEY,
                  POST_MENU_SHOW_MORE_BUTTON_KEY,
                ],
                after: POST_MENU_DELETE_BUTTON_KEY,
              }
            : {
                before: [
                  "assign", // button added by the assign plugin
                  POST_MENU_LIKE_BUTTON_KEY,
                  POST_MENU_COPY_LINK_BUTTON_KEY,
                  POST_MENU_SHARE_BUTTON_KEY,
                  POST_MENU_SHOW_MORE_BUTTON_KEY,
                ],
              }
        );
    }
  );

  const silencedKey =
    transformerRegistered && "discourse.post-menu-widget-overrides";

  withSilencedDeprecations(silencedKey, () => customizeWidgetPostMenu(api));
}

function customizeWidgetPostMenu(api) {
  const currentUser = api.getCurrentUser();

  api.addPostMenuButton("solved", (attrs) => {
    if (attrs.can_accept_answer) {
      const isOp = currentUser?.id === attrs.topicCreatedById;

      return {
        action: "acceptAnswer",
        icon: "far-check-square",
        className: "unaccepted",
        title: "solved.accept_answer",
        label: isOp ? "solved.solution" : null,
        position: attrs.topic_accepted_answer ? "second-last-hidden" : "first",
      };
    } else if (attrs.accepted_answer) {
      if (attrs.can_unaccept_answer) {
        return {
          action: "unacceptAnswer",
          icon: "check-square",
          title: "solved.unaccept_answer",
          className: "accepted fade-out",
          position: "first",
          label: "solved.solution",
        };
      } else {
        return {
          className: "hidden",
          disabled: "true",
          position: "first",
          beforeButton(h) {
            return h(
              "span.accepted-text",
              {
                title: I18n.t("solved.accepted_description"),
              },
              [
                h("span", iconNode("check")),
                h("span.accepted-label", I18n.t("solved.solution")),
              ]
            );
          },
        };
      }
    }
  });
}

export default {
  name: "extend-for-solved-button",
  initialize() {
    Topic.reopen({
      // keeping this here cause there is complex localization
      acceptedAnswerHtml: computed("accepted_answer", "id", function () {
        const username = this.get("accepted_answer.username");
        const name = this.get("accepted_answer.name");
        const postNumber = this.get("accepted_answer.post_number");

        if (!username || !postNumber) {
          return "";
        }

        const displayedUser =
          this.siteSettings.display_name_on_posts && name
            ? name
            : formatUsername(username);

        return I18n.t("solved.accepted_html", {
          icon: iconHTML("check-square", { class: "accepted" }),
          username_lower: username.toLowerCase(),
          username: displayedUser,
          post_path: `${this.url}/${postNumber}`,
          post_number: postNumber,
          user_path: User.create({ username }).path,
        });
      }),
    });

    TopicStatus.reopen({
      statuses: computed(function () {
        const results = this._super(...arguments);

        if (this.topic.has_accepted_answer) {
          results.push({
            openTag: "span",
            closeTag: "span",
            title: I18n.t("topic_statuses.solved.help"),
            icon: "far-check-square",
            key: "solved",
          });
        } else if (
          this.topic.can_have_answer &&
          this.siteSettings.solved_enabled &&
          this.siteSettings.empty_box_on_unsolved
        ) {
          results.push({
            openTag: "span",
            closeTag: "span",
            title: I18n.t("solved.has_no_accepted_answer"),
            icon: "far-square",
          });
        }
        return results;
      }),
    });

    withPluginApi("1.34.0", initializeWithApi);

    withPluginApi("0.8.10", (api) => {
      api.replaceIcon(
        "notification.solved.accepted_notification",
        "check-square"
      );
    });

    withPluginApi("0.11.0", (api) => {
      api.addAdvancedSearchOptions({
        statusOptions: [
          {
            name: I18n.t("search.advanced.statuses.solved"),
            value: "solved",
          },
          {
            name: I18n.t("search.advanced.statuses.unsolved"),
            value: "unsolved",
          },
        ],
      });
    });

    withPluginApi("0.11.7", (api) => {
      api.addSearchSuggestion("status:solved");
      api.addSearchSuggestion("status:unsolved");
    });
  },
};

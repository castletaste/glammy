import glammy/types
import gleam/json
import gleam/option.{None, Some}
import gleam/string

pub fn decodes_poll_update_test() {
  let body =
    "{
      \"update_id\":10,
      \"poll\":{
        \"id\":\"p1\",
        \"question\":\"Yes?\",
        \"options\":[{\"persistent_id\":\"yes\",\"text\":\"y\",\"voter_count\":1},{\"persistent_id\":\"no\",\"text\":\"n\",\"voter_count\":0}],
        \"total_voter_count\":1,
        \"is_closed\":false,
        \"is_anonymous\":true,
        \"type\":\"regular\",
        \"allows_multiple_answers\":false,
        \"allows_revoting\":true,
        \"members_only\":false
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.PollUpdate(p) -> {
      assert p.question == "Yes?"
      assert p.total_voter_count == 1
    }
    _ -> panic as "expected PollUpdate"
  }
}

pub fn decodes_chat_member_update_test() {
  let body =
    "{
      \"update_id\":11,
      \"chat_member\":{
        \"chat\":{\"id\":1,\"type\":\"supergroup\",\"title\":\"G\"},
        \"from\":{\"id\":2,\"is_bot\":false,\"first_name\":\"A\"},
        \"date\":1700000000,
        \"old_chat_member\":{\"status\":\"member\",\"tag\":\"reader\",\"user\":{\"id\":3,\"is_bot\":false,\"first_name\":\"B\"}},
        \"new_chat_member\":{\"status\":\"left\",\"user\":{\"id\":3,\"is_bot\":false,\"first_name\":\"B\"}},
        \"via_join_request\":true
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.ChatMemberUpdate(c) -> {
      assert c.chat.id == 1
      case c.old_chat_member {
        types.ChatMemberMember(u, _, tag) -> {
          assert u.first_name == "B"
          assert tag == Some("reader")
        }
        _ -> panic as "expected ChatMemberMember"
      }
      case c.new_chat_member {
        types.ChatMemberLeft(u) -> {
          assert u.first_name == "B"
        }
        _ -> panic as "expected ChatMemberLeft"
      }
      assert c.via_join_request == Some(True)
    }
    _ -> panic as "expected ChatMemberUpdate"
  }
}

pub fn decodes_chat_join_request_test() {
  let body =
    "{
      \"update_id\":12,
      \"chat_join_request\":{
        \"chat\":{\"id\":-100,\"type\":\"channel\",\"title\":\"Ch\"},
        \"from\":{\"id\":99,\"is_bot\":false,\"first_name\":\"User\"},
        \"user_chat_id\":99,
        \"date\":1700000000,
        \"query_id\":\"join-query-1\"
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.ChatJoinRequestUpdate(r) -> {
      assert r.user_chat_id == 99
      assert r.from.first_name == "User"
      assert r.query_id == Some("join-query-1")
    }
    _ -> panic as "expected ChatJoinRequestUpdate"
  }
}

pub fn decodes_pre_checkout_query_test() {
  let body =
    "{
      \"update_id\":13,
      \"pre_checkout_query\":{
        \"id\":\"pc1\",
        \"from\":{\"id\":1,\"is_bot\":false,\"first_name\":\"Buyer\"},
        \"currency\":\"USD\",
        \"total_amount\":1000,
        \"invoice_payload\":\"order-42\"
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.PreCheckoutQueryUpdate(p) -> {
      assert p.currency == "USD"
      assert p.total_amount == 1000
      assert p.invoice_payload == "order-42"
    }
    _ -> panic as "expected PreCheckoutQueryUpdate"
  }
}

pub fn decodes_reaction_update_test() {
  let body =
    "{
      \"update_id\":14,
      \"message_reaction\":{
        \"chat\":{\"id\":1,\"type\":\"group\",\"title\":\"G\"},
        \"message_id\":42,
        \"user\":{\"id\":2,\"is_bot\":false,\"first_name\":\"R\"},
        \"date\":1700000000,
        \"old_reaction\":[],
        \"new_reaction\":[{\"type\":\"emoji\",\"emoji\":\"🔥\"}]
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.MessageReactionUpdate(r) -> {
      assert r.message_id == 42
      case r.new_reaction {
        [types.ReactionEmoji(e)] -> {
          assert e == "🔥"
        }
        _ -> panic as "expected single ReactionEmoji"
      }
    }
    _ -> panic as "expected MessageReactionUpdate"
  }
}

pub fn decodes_message_with_photo_test() {
  let body =
    "{
      \"update_id\":15,
      \"message\":{
        \"message_id\":1,
        \"chat\":{\"id\":1,\"type\":\"private\"},
        \"date\":0,
        \"photo\":[
          {\"file_id\":\"a\",\"file_unique_id\":\"ua\",\"width\":90,\"height\":90,\"file_size\":1000},
          {\"file_id\":\"b\",\"file_unique_id\":\"ub\",\"width\":320,\"height\":320,\"file_size\":2000}
        ],
        \"caption\":\"a kitten\"
      }
    }"
  let assert Ok(u) = json.parse(body, types.update_decoder())
  case u.kind {
    types.MessageUpdate(m) -> {
      assert m.caption == Some("a kitten")
      case m.photo {
        [first, _] -> {
          assert first.width == 90
          assert first.file_size == Some(1000)
        }
        _ -> panic as "expected two photo sizes"
      }
    }
    _ -> panic as "expected MessageUpdate"
  }
}

pub fn webhook_info_decoder_test() {
  let body =
    "{
      \"url\":\"https://example.com/wh\",
      \"has_custom_certificate\":false,
      \"pending_update_count\":0,
      \"allowed_updates\":[\"message\",\"callback_query\"]
    }"
  let assert Ok(w) = json.parse(body, types.webhook_info_decoder())
  assert w.url == "https://example.com/wh"
  assert w.has_custom_certificate == False
  assert w.allowed_updates == ["message", "callback_query"]
  assert w.ip_address == None
}

pub fn decodes_current_update_variants_test() {
  let guest_body =
    "{\"update_id\":20,\"guest_message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"private\"},\"date\":0,\"text\":\"hi\",\"receiver_user\":{\"id\":7,\"is_bot\":false,\"first_name\":\"Receiver\"},\"ephemeral_message_id\":41,\"guest_query_id\":\"guest-20\",\"guest_bot_caller_user\":{\"id\":8,\"is_bot\":false,\"first_name\":\"Caller\"},\"guest_bot_caller_chat\":{\"id\":9,\"type\":\"private\"}}}"
  let assert Ok(guest) = json.parse(guest_body, types.update_decoder())
  case guest.kind {
    types.GuestMessageUpdate(message) -> {
      assert message.text == Some("hi")
      assert message.ephemeral_message_id == Some(41)
      assert message.guest_query_id == Some("guest-20")
      let assert Some(receiver) = message.receiver_user
      assert receiver.id == 7
      let assert Some(caller) = message.guest_bot_caller_user
      assert caller.id == 8
      let assert Some(caller_chat) = message.guest_bot_caller_chat
      assert caller_chat.id == 9
    }
    _ -> panic as "expected GuestMessageUpdate"
  }

  let managed_body =
    "{\"update_id\":21,\"managed_bot\":{\"user\":{\"id\":1,\"is_bot\":false,\"first_name\":\"Owner\"},\"bot\":{\"id\":2,\"is_bot\":true,\"first_name\":\"Managed\"}}}"
  let assert Ok(managed) = json.parse(managed_body, types.update_decoder())
  case managed.kind {
    types.ManagedBotUpdate(update) -> {
      assert update.user.first_name == "Owner"
      assert update.bot.first_name == "Managed"
    }
    _ -> panic as "expected ManagedBotUpdate"
  }

  let subscription_body =
    "{\"update_id\":22,\"subscription\":{\"user\":{\"id\":1,\"is_bot\":false,\"first_name\":\"Buyer\"},\"invoice_payload\":\"plan-pro\",\"state\":\"active\"}}"
  let assert Ok(subscription) =
    json.parse(subscription_body, types.update_decoder())
  case subscription.kind {
    types.SubscriptionUpdate(update) -> {
      assert update.invoice_payload == "plan-pro"
      assert update.state == types.SubscriptionActive
    }
    _ -> panic as "expected SubscriptionUpdate"
  }
}

pub fn sticker_preserves_premium_animation_file_test() {
  let body =
    "{\"file_id\":\"sticker\",\"file_unique_id\":\"unique\",\"type\":\"regular\",\"width\":512,\"height\":512,\"is_animated\":true,\"is_video\":false,\"premium_animation\":{\"file_id\":\"premium\",\"file_unique_id\":\"premium-unique\",\"file_size\":123}}"
  let assert Ok(sticker) = json.parse(body, types.sticker_decoder())
  let assert Some(animation) = sticker.premium_animation
  assert animation.file_id == "premium"
  assert animation.file_unique_id == "premium-unique"
  assert animation.file_size == Some(123)
}

pub fn decodes_current_chat_member_fields_test() {
  let administrator_body =
    "{
      \"status\":\"administrator\",
      \"user\":{\"id\":3,\"is_bot\":false,\"first_name\":\"Admin\"},
      \"can_be_edited\":true,
      \"is_anonymous\":false,
      \"can_manage_chat\":true,
      \"can_delete_messages\":true,
      \"can_manage_video_chats\":true,
      \"can_restrict_members\":true,
      \"can_promote_members\":true,
      \"can_change_info\":true,
      \"can_invite_users\":true,
      \"can_post_stories\":true,
      \"can_edit_stories\":false,
      \"can_delete_stories\":true,
      \"can_manage_direct_messages\":true,
      \"can_manage_tags\":false
    }"
  let assert Ok(administrator) =
    json.parse(administrator_body, types.chat_member_decoder())
  case administrator {
    types.ChatMemberAdministrator(
      can_post_stories:,
      can_edit_stories:,
      can_delete_stories:,
      can_manage_direct_messages:,
      can_manage_tags:,
      ..,
    ) -> {
      assert can_post_stories
      assert !can_edit_stories
      assert can_delete_stories
      assert can_manage_direct_messages == Some(True)
      assert can_manage_tags == Some(False)
    }
    _ -> panic as "expected ChatMemberAdministrator"
  }

  let assert Error(_) =
    json.parse(
      string.replace(administrator_body, "\"can_post_stories\":true,", ""),
      types.chat_member_decoder(),
    )
  let assert Error(_) =
    json.parse(
      string.replace(administrator_body, "\"can_edit_stories\":false,", ""),
      types.chat_member_decoder(),
    )
  let assert Error(_) =
    json.parse(
      string.replace(administrator_body, "\"can_delete_stories\":true,", ""),
      types.chat_member_decoder(),
    )

  let restricted_body =
    "{
      \"status\":\"restricted\",
      \"tag\":\"helper\",
      \"user\":{\"id\":4,\"is_bot\":false,\"first_name\":\"Restricted\"},
      \"is_member\":true,
      \"can_send_messages\":true,
      \"can_send_audios\":true,
      \"can_send_documents\":true,
      \"can_send_photos\":true,
      \"can_send_videos\":true,
      \"can_send_video_notes\":true,
      \"can_send_voice_notes\":true,
      \"can_send_polls\":true,
      \"can_send_other_messages\":true,
      \"can_add_web_page_previews\":true,
      \"can_react_to_messages\":true,
      \"can_edit_tag\":false,
      \"can_change_info\":false,
      \"can_invite_users\":false,
      \"can_pin_messages\":false,
      \"can_manage_topics\":false,
      \"until_date\":0
    }"
  let assert Ok(restricted) =
    json.parse(restricted_body, types.chat_member_decoder())
  case restricted {
    types.ChatMemberRestricted(can_react_to_messages:, can_edit_tag:, tag:, ..) -> {
      assert can_react_to_messages
      assert !can_edit_tag
      assert tag == Some("helper")
    }
    _ -> panic as "expected ChatMemberRestricted"
  }
}

pub fn decodes_current_successful_payment_fields_test() {
  let body =
    "{
      \"currency\":\"XTR\",
      \"total_amount\":100,
      \"invoice_payload\":\"monthly\",
      \"subscription_expiration_date\":1800000000,
      \"is_recurring\":true,
      \"is_first_recurring\":true,
      \"telegram_payment_charge_id\":\"tg-charge\",
      \"provider_payment_charge_id\":\"provider-charge\"
    }"
  let assert Ok(payment) = json.parse(body, types.successful_payment_decoder())
  assert payment.subscription_expiration_date == Some(1_800_000_000)
  assert payment.is_recurring == Some(True)
  assert payment.is_first_recurring == Some(True)
}

pub fn decodes_current_business_connection_rights_test() {
  let body =
    "{
      \"id\":\"business-1\",
      \"user\":{\"id\":7,\"is_bot\":false,\"first_name\":\"Owner\"},
      \"user_chat_id\":700,
      \"date\":1700000000,
      \"rights\":{
        \"can_reply\":true,
        \"can_read_messages\":true,
        \"can_delete_sent_messages\":true,
        \"can_delete_all_messages\":true,
        \"can_edit_name\":true,
        \"can_edit_bio\":true,
        \"can_edit_profile_photo\":true,
        \"can_edit_username\":true,
        \"can_change_gift_settings\":true,
        \"can_view_gifts_and_stars\":true,
        \"can_convert_gifts_to_stars\":true,
        \"can_transfer_and_upgrade_gifts\":true,
        \"can_transfer_stars\":true,
        \"can_manage_stories\":true
      },
      \"is_enabled\":true
    }"
  let assert Ok(connection) =
    json.parse(body, types.business_connection_decoder())
  let assert Some(rights) = connection.rights
  assert rights.can_reply == Some(True)
  assert rights.can_read_messages == Some(True)
  assert rights.can_manage_stories == Some(True)
}

pub fn decodes_chat_invite_link_subscription_fields_test() {
  let body =
    "{
      \"invite_link\":\"https://t.me/+paid\",
      \"creator\":{\"id\":7,\"is_bot\":false,\"first_name\":\"Owner\"},
      \"creates_join_request\":true,
      \"is_primary\":false,
      \"is_revoked\":false,
      \"subscription_period\":2592000,
      \"subscription_price\":250
    }"
  let assert Ok(link) = json.parse(body, types.chat_invite_link_decoder())
  assert link.subscription_period == Some(2_592_000)
  assert link.subscription_price == Some(250)
}

pub fn unknown_nested_discriminators_do_not_poison_updates_test() {
  let chat_body =
    "{\"update_id\":30,\"message\":{\"message_id\":1,\"chat\":{\"id\":1,\"type\":\"future_chat\"},\"date\":0}}"
  let assert Ok(chat_update) = json.parse(chat_body, types.update_decoder())
  let assert types.MessageUpdate(chat_message) = chat_update.kind
  assert chat_message.chat.type_ == types.UnknownChatType("future_chat")

  let sticker_body =
    "{\"file_id\":\"s\",\"file_unique_id\":\"u\",\"type\":\"future_sticker\",\"width\":1,\"height\":1,\"is_animated\":false,\"is_video\":false}"
  let assert Ok(sticker) = json.parse(sticker_body, types.sticker_decoder())
  assert sticker.type_ == types.UnknownStickerType("future_sticker")

  let reaction_body = "{\"type\":\"future_reaction\",\"extra\":42}"
  let assert Ok(reaction) =
    json.parse(reaction_body, types.reaction_type_decoder())
  let assert types.UnknownReactionType("future_reaction", _) = reaction

  let member_body = "{\"status\":\"future_member\",\"extra\":42}"
  let assert Ok(member) = json.parse(member_body, types.chat_member_decoder())
  let assert types.UnknownChatMember("future_member", _) = member

  let boost_body = "{\"source\":\"future_boost\",\"extra\":42}"
  let assert Ok(boost) =
    json.parse(boost_body, types.chat_boost_source_decoder())
  let assert types.UnknownChatBoostSource("future_boost", _) = boost
}

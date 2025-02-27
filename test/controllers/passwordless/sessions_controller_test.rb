# frozen_string_literal: true

require "test_helper"

module Passwordless
  class SessionsControllerTest < ActionDispatch::IntegrationTest
    def create_session_for(user)
      Session.create!(authenticatable: user)
    end

    class Helpers
      extend Passwordless::ControllerHelpers
    end

    test("requesting a magic link as an existing user") do
      User.create email: "a@a"

      get "/users/sign_in"
      assert_equal 200, status

      post(
        "/users/sign_in",
        params: {passwordless: {email: "A@a"}},
        headers: {:"User-Agent" => "an actual monkey"}
      )
      assert_equal 302, status
      assert_equal "/users/sign_in", path

      assert_equal 1, ActionMailer::Base.deliveries.size
    end

    test("magic link will send by custom method") do
      old_proc = Passwordless.config.after_session_save
      called = false
      Passwordless.config.after_session_save = -> (_) { called = true }

      User.create email: "a@a"

      post(
        "/users/sign_in",
        params: {passwordless: {email: "A@a"}},
        headers: {:"User-Agent" => "an actual monkey"}
      )
      assert_equal 302, status

      assert_equal true, called

      Passwordless.config.after_session_save = old_proc
    end

    test("magic link will send by custom method (with request param)") do
      old_proc = Passwordless.config.after_session_save
      called = false
      Passwordless.config.after_session_save = -> (_, _) { called = true }

      User.create email: "a@a"

      post(
        "/users/sign_in",
        params: {passwordless: {email: "A@a"}},
        headers: {:"User-Agent" => "an actual monkey"}
      )
      assert_equal 302, status

      assert_equal true, called

      Passwordless.config.after_session_save = old_proc
    end

    test("requesting a magic link as an unknown user") do
      get "/users/sign_in"
      assert_equal 200, status

      post(
        "/users/sign_in",
        params: {passwordless: {email: "invalidemail"}},
        headers: {:"User-Agent" => "an actual monkey"}
      )
      assert_equal 302, status

      assert_equal 0, ActionMailer::Base.deliveries.size
    end

    test("requesting a magic link with overridden fetch method") do
      def User.fetch_resource_for_passwordless(email)
        User.find_or_create_by(email: email)
      end

      get "/users/sign_in"
      assert_equal 200, status

      post(
        "/users/sign_in",
        params: {passwordless: {email: "overriden_email@example"}},
        headers: {:"User-Agent" => "an actual monkey"}
      )
      assert_equal 302, status

      assert_equal 1, ActionMailer::Base.deliveries.size

      class << User
        remove_method :fetch_resource_for_passwordless
      end
    end

    test("signing in via a token") do
      user = User.create(email: "a@a")
      passwordless_session = create_session_for(user)

      get "/users/sign_in/#{passwordless_session.token}"
      follow_redirect!

      assert_equal 200, status
      assert_equal "/", path
      assert_not_nil session[Helpers.session_key(user.class)]
    end

    test("reset session id when signing in via a token") do
      user = User.create(email: "a@a")
      passwordless_session = create_session_for(user)

      get "/users/sign_in/#{passwordless_session.token}"
      old_session_id = @request.session_options[:id].to_s

      get "/users/sign_in/#{passwordless_session.token}"
      new_session_id = @request.session_options[:id].to_s

      assert_not_equal old_session_id, new_session_id
    end

    test("signing in via a token as STI model") do
      admin = Admin.create(email: "a@a")
      passwordless_session = create_session_for(admin)

      get "/users/sign_in/#{passwordless_session.token}"
      follow_redirect!

      assert_equal 200, status
      assert_equal "/", path
      assert_not_nil session[Helpers.session_key(admin.class)]
    end

    test("signing in and redirecting back") do
      user = User.create!(email: "a@a")

      get "/secret"
      assert_equal 302, status

      follow_redirect!
      assert_equal 200, status

      passwordless_session = create_session_for(user)
      get "/users/sign_in/#{passwordless_session.token}"
      follow_redirect!

      assert_equal 200, status
      assert_equal "/secret", path
      assert_nil session[Helpers.redirect_session_key(User)]
    end

    test("signing in and redirecting via query parameter") do
      Passwordless.config.restrict_token_reuse = false
      user = User.create!(email: "a@a")

      get "/secret"
      assert_equal 302, status

      follow_redirect!
      assert_equal 200, status

      # Test without domain
      passwordless_session = create_session_for(user)
      get "/users/sign_in/#{passwordless_session.token}?destination_path=/secret-alt"
      follow_redirect!

      assert_equal 200, status
      assert_equal "/secret-alt", path

      # Text complete url
      passwordless_session = create_session_for(user)
      get "/users/sign_in/#{passwordless_session.token}?destination_path=http://www.example.com/secret-alt"
      follow_redirect!

      assert_equal 200, status
      assert_equal "/secret-alt", path
    end

    test("signing in and redirecting via insecure query parameter") do
      user = User.create!(email: "a@a")
      passwordless_session = create_session_for(user)
      get "/users/sign_in/#{passwordless_session.token}?destination_path=http://insecure.example.org/secret-alt"
      follow_redirect!

      assert_equal 200, status
      assert_equal Passwordless.config.success_redirect_path, path
    end

    test("signing in and redirecting with redirect_to options") do
      Passwordless.config.redirect_to_response_options = {notice: "hello!"}

      user = User.create!(email: "a@a")
      passwordless_session = create_session_for(user)
      get "/users/sign_in/#{passwordless_session.token}"
      follow_redirect!

      assert_equal "hello!", flash[:notice]
      assert_equal 200, status
      assert_equal Passwordless.config.success_redirect_path, path
    end

    test("disabling redirecting back after sign in") do
      default = Passwordless.config.redirect_back_after_sign_in
      Passwordless.config.redirect_back_after_sign_in = false

      user = User.create!(email: "a@a")

      get "/secret"
      assert_equal 302, status

      follow_redirect!
      assert_equal 200, status

      passwordless_session = create_session_for(user)
      get "/users/sign_in/#{passwordless_session.token}"
      follow_redirect!

      assert_equal "/", path

      Passwordless.config.redirect_back_after_sign_in = default
    end

    test("trying to sign in with an unknown token") do
      assert_raise(ActiveRecord::RecordNotFound) do
        get "/users/sign_in/twin-hotdogs"
      end
    end

    test("signing out") do
      user = User.create(email: "a@a")

      passwordless_session = create_session_for(user)
      get "/users/sign_in/#{passwordless_session.token}"
      assert_not_nil session[Helpers.session_key(user.class)]

      get "/users/sign_out"
      follow_redirect!

      assert_equal 200, status
      assert_equal "/", path
      assert session[Helpers.session_key(user.class)].blank?
    end

    test("reset session id when signing out") do
      user = User.create(email: "a@a")
      passwordless_session = create_session_for(user)
      get "/users/sign_in/#{passwordless_session.token}"

      old_session_id = @request.session_options[:id].to_s
      get "/users/sign_out"
      new_session_id = @request.session_options[:id].to_s

      assert_not_equal old_session_id, new_session_id
    end

    test("signing out with redirect_to options") do
      Passwordless.config.redirect_to_response_options = {notice: "bye!"}

      user = User.create(email: "a@a")
      passwordless_session = create_session_for(user)
      get "/users/sign_in/#{passwordless_session.token}"
      assert_not_nil session[Helpers.session_key(user.class)]

      get "/users/sign_out"

      follow_redirect!

      assert_equal "bye!", flash[:notice]
      assert_equal 200, status
      assert_equal "/", path
      assert session[Helpers.session_key(user.class)].blank?
    end

    test("trying to sign in with an timed out session") do
      user = User.create(email: "a@a")
      passwordless_session = create_session_for(user)
      passwordless_session.update!(timeout_at: Time.current - 1.day)

      get "/users/sign_in/#{passwordless_session.token}"
      follow_redirect!

      assert_match "Your session has expired", flash[:error]
      assert_nil session[Helpers.session_key(user.class)]
      assert_equal 200, status
      assert_equal "/", path
    end

    test("trying to use a claimed token") do
      default = Passwordless.config.restrict_token_reuse
      Passwordless.config.restrict_token_reuse = true
      user = User.create(email: "a@a")
      passwordless_session = create_session_for(user)

      get "/users/sign_in/#{passwordless_session.token}"
      follow_redirect!
      assert_not_nil session[Helpers.session_key(user.class)]

      get "/users/sign_out"
      follow_redirect!
      assert_equal true, passwordless_session.reload.claimed?

      get "/users/sign_in/#{passwordless_session.token}"

      assert_match "This link has already been used", flash[:error]
      assert_nil session[Helpers.session_key(user.class)]
      follow_redirect!
      assert_equal 200, status
      assert_equal "/", path

      Passwordless.config.restrict_token_reuse = default
    end

    test("responding to HEAD requests") do
      user = User.create(email: "a@a")
      passwordless_session = create_session_for(user)

      token_path = "/users/sign_in/#{passwordless_session.token}"
      head token_path

      assert_equal 200, status
      assert_equal token_path, path
      assert_nil session[Helpers.session_key(user.class)]
    end
  end
end

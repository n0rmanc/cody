class ReceivePullRequestEvent
  include Sidekiq::Worker

  def perform(payload)
    @payload = payload

    case @payload["action"]
    when "opened"
      self.on_opened
    when "synchronize"
      self.on_synchronize
    end
  end

  def on_opened
    Rails.logger.debug "perform_async============"
    CreateOrUpdatePullRequest.new.perform(@payload["pull_request"])
  end

  # The "synchronize" event occurs whenever a new commit is pushed to the branch
  # or the branch is rebased.
  #
  # In this case, we preserve the current review status and update the new
  # commit with the correct status indicator.
  def on_synchronize
    number = @payload["number"]
    repository = @payload['repository']['full_name']

    if pr = PullRequest.find_by(number: number, repository: repository)

      status = "pending"
      description = "Not all reviewers have approved. Comment \"LGTM\" to give approval."

      if pr.status == "approved"
        status = "success"
        description = "Code review complete"
      end

      pr_sha = @payload["pull_request"]["head"]["sha"]

      github = Octokit::Client.new(access_token: ENV["CODY_GITHUB_ACCESS_TOKEN"])
      github.create_status(
        @payload["repository"]["full_name"],
        pr_sha,
        status,
        context: "code-review/cody",
        description: description,
        target_url: Setting.lookup("status_target_url")
      )
    else
      CreateOrUpdatePullRequest.new.perform(@payload["pull_request"])
    end
  end
end

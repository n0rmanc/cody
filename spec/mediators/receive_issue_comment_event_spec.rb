require 'rails_helper'

RSpec.describe ReceiveIssueCommentEvent do
  let(:reviewer) { "aergonaut" }

  let(:pending_reviews) { [reviewer] }

  let!(:pr) { FactoryGirl.create :pull_request, status: "pending_review", pending_reviews: pending_reviews }

  let(:payload) do
    from_fixture = JSON.load(File.open(Rails.root.join("spec", "fixtures", "issue_comment.json")))
    from_fixture["issue"]["number"] = pr.number
    from_fixture["sender"]["login"] = sender
    from_fixture["comment"]["body"] = comment
    from_fixture
  end

  let(:job) { ReceiveIssueCommentEvent.new }

  let(:sender) { reviewer }

  describe "#perform" do
    before do
      stub_request(:post, %r(https?://api.github.com/repos/\w+/\w+/statuses/[0-9abcdef]{40}))
      stub_request(:get, %r(https?://api.github.com/repos/\w+/\w+/pulls/\d+)).to_return(
        body: pr_response_body,
        status: 200,
        headers: { "Content-Type" => "application/json" }
      )
      job.perform(payload)
    end

    context "when submitting an approval" do
      let(:comment) { "lgtm" }

      let(:pr_response_body) { File.open(Rails.root.join("spec", "fixtures", "pr.json")) }

      context "when the commenter is a reviewer" do
        context "and they approve" do
          it "moves them into the completed_reviews list" do
            pr.reload
            expect(pr.pending_reviews).to_not include(reviewer)
            expect(pr.completed_reviews).to include(sender)
          end

          context "and they are the last approver" do
            it "updates the status on GitHub" do
              expect(WebMock).to have_requested(:post, %r(https?://api.github.com/repos/\w+/\w+/statuses/[0-9abcdef]{40}))
            end

            it "marks the PR as approved" do
              expect(pr.reload.status).to eq("approved")
            end
          end

          context "but their username has different capitalization than what we recorded in the reviews list" do
            let(:sender) { "AeRgOnAuT" }

            it "moves them into the completed_reviews list" do
              pr.reload
              expect(pr.pending_reviews).to_not include(reviewer)
              expect(pr.completed_reviews).to include(sender)
            end
          end

          context "and they approve with a literal emoji" do
            let(:comment) { "👍" }

            it "moves them into the completed_reviews list" do
              pr.reload
              expect(pr.pending_reviews).to_not include(reviewer)
              expect(pr.completed_reviews).to include(sender)
            end
          end
        end
      end
    end

    context "when rebuilding reviews" do
      let(:comment) { "!rebuild-reviews" }

      let(:author) { "metakube" }

      let(:pr_response_body) do
        from_fixture = JSON.load(File.open(Rails.root.join("spec", "fixtures", "pr.json")))
        from_fixture["number"] = pr.number
        from_fixture["body"] = "- [ ] @aergonaut\n- [ ] @BrentW"
        from_fixture["user"]["login"] = author
        JSON.dump(from_fixture)
      end

      before do
        expect(ApplyReviewRules).to_not receive(:new)
      end

      context "when the commenter is the PR author" do
        let(:sender) { author }

        it "rebuilds the reviewers from the PR body" do
          pr.reload
          expect(pr.pending_reviews).to contain_exactly("aergonaut", "BrentW")
        end
      end

      context "when the commenter is one of the previous reviewers" do
        let(:sender) { pr.pending_reviews.first }

        it "rebuilds the reviewers from the PR body" do
          pr.reload
          expect(pr.pending_reviews).to contain_exactly("aergonaut", "BrentW")
        end
      end
    end
  end
end

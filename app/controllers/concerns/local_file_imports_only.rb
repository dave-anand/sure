module LocalFileImportsOnly
  extend ActiveSupport::Concern

  private
    def enforce_local_file_web_policy
      return if controller_path.start_with?("api/")
      reject_external_integration if external_integration_disabled?
    end

    def enforce_local_file_api_policy
      reject_external_integration if external_integration_disabled?
    end

    def external_integration_disabled?
      LocalFileMode.enabled? && LocalFileMode.external_controller?(controller_path)
    end

    def reject_external_integration
      if request.format.html?
        redirect_to accounts_path, alert: t("accounts.index.local_file_mode_description")
      else
        render json: { error: "local_file_mode", message: "Live integrations are disabled; import local files instead" }, status: :forbidden
      end
    end
end

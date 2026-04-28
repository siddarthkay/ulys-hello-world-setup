# Budget currency must match the billing account's currency or the API
# rejects with a generic "invalid argument" 400. We look it up and pick a
# rough $20 equivalent.
data "google_billing_account" "this" {
  billing_account = var.billing_account_id
}

locals {
  budget_amounts = {
    USD = "20"
    INR = "1700"
    EUR = "18"
    GBP = "16"
    AUD = "30"
    CAD = "27"
    SGD = "27"
    JPY = "3000"
  }
  budget_amount = lookup(local.budget_amounts, data.google_billing_account.this.currency_code, "20")
}

resource "google_monitoring_notification_channel" "budget_email" {
  display_name = "${var.name_prefix} budget alert email"
  type         = "email"
  labels = {
    email_address = var.budget_alert_email
  }
  depends_on = [google_project_service.apis]
}

resource "google_billing_budget" "twenty_dollar" {
  billing_account = var.billing_account_id
  display_name    = "${var.name_prefix}-budget"

  budget_filter {
    projects = ["projects/${var.project_number}"]
  }

  amount {
    specified_amount {
      currency_code = data.google_billing_account.this.currency_code
      units         = local.budget_amount
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }

  all_updates_rule {
    monitoring_notification_channels = [
      google_monitoring_notification_channel.budget_email.id,
    ]
    disable_default_iam_recipients = false
  }

  depends_on = [google_project_service.apis]
}

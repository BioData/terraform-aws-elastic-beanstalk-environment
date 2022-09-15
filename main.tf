locals {
  enabled   = var.enabled
  partition = join("", data.aws_partition.current.*.partition)
}

data "aws_partition" "current" {
  count = local.enabled ? 1 : 0
}

#
# Service
#
data "aws_iam_policy_document" "service" {
  count = local.enabled ? 1 : 0

  statement {
    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type        = "Service"
      identifiers = ["elasticbeanstalk.amazonaws.com"]
    }

    effect = "Allow"
  }
}

resource "aws_iam_role" "service" {
  count = local.enabled ? 1 : 0

  name               = "BioData-${var.elastic_beanstalk_environment_name}-eb-service-role"
  assume_role_policy = join("", data.aws_iam_policy_document.service.*.json)
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "enhanced_health" {
  count = local.enabled && var.enhanced_reporting_enabled ? 1 : 0

  role       = join("", aws_iam_role.service.*.name)
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSElasticBeanstalkEnhancedHealth"
}

resource "aws_iam_role_policy_attachment" "service" {
  count = local.enabled ? 1 : 0

  role       = join("", aws_iam_role.service.*.name)
  policy_arn = var.prefer_legacy_service_policy ? "arn:${local.partition}:iam::aws:policy/service-role/AWSElasticBeanstalkService" : "arn:${local.partition}:iam::aws:policy/AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy"
}

#
# EC2
#
data "aws_iam_policy_document" "ec2" {
  count = local.enabled ? 1 : 0

  statement {
    sid = ""

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    effect = "Allow"
  }

  statement {
    sid = ""

    actions = [
      "sts:AssumeRole",
    ]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    effect = "Allow"
  }
}

resource "aws_iam_role" "ec2" {
  count = local.enabled ? 1 : 0

  name               = "BioData-${var.elastic_beanstalk_environment_name}-eb-ec2-role"
  assume_role_policy = join("", data.aws_iam_policy_document.ec2.*.json)
  tags               = var.tags
}

resource "aws_iam_role_policy" "default" {
  count = local.enabled ? 1 : 0

  name   = "BioData-${var.elastic_beanstalk_environment_name}-eb-default-policy"
  role   = join("", aws_iam_role.ec2.*.id)
  policy = join("", data.aws_iam_policy_document.extended.*.json)
}

resource "aws_iam_role_policy_attachment" "web_tier" {
  count = local.enabled && var.tier == "WebServer" ? 1 : 0

  role       = join("", aws_iam_role.ec2.*.name)
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSElasticBeanstalkWebTier"
}

resource "aws_iam_role_policy_attachment" "ec2_ecs_policy" {
  count = local.enabled && var.is_ecs_platform ? 1 : 0

  role       = join("", aws_iam_role.ec2.*.name)
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSElasticBeanstalkMulticontainerDocker"
}

resource "aws_iam_role_policy_attachment" "worker_tier" {
  count = local.enabled && var.tier == "Worker" ? 1 : 0

  role       = join("", aws_iam_role.ec2.*.name)
  policy_arn = "arn:${local.partition}:iam::aws:policy/AWSElasticBeanstalkWorkerTier"
}

resource "aws_iam_role_policy_attachment" "ssm_ec2" {
  count = local.enabled ? 1 : 0

  role       = join("", aws_iam_role.ec2.*.name)
  policy_arn = var.prefer_legacy_ssm_policy ? "arn:${local.partition}:iam::aws:policy/service-role/AmazonEC2RoleforSSM" : "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "ssm_automation" {
  count = local.enabled ? 1 : 0

  role       = join("", aws_iam_role.ec2.*.name)
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonSSMAutomationRole"

  lifecycle {
    create_before_destroy = true
  }
}

# http://docs.aws.amazon.com/elasticbeanstalk/latest/dg/create_deploy_docker.container.console.html
# http://docs.aws.amazon.com/AmazonECR/latest/userguide/ecr_managed_policies.html#AmazonEC2ContainerRegistryReadOnly
resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  count = local.enabled ? 1 : 0

  role       = join("", aws_iam_role.ec2.*.name)
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_ssm_activation" "ec2" {
  count = local.enabled ? 1 : 0

  name               = var.elastic_beanstalk_environment_name
  iam_role           = join("", aws_iam_role.ec2.*.id)
  registration_limit = var.autoscale_max
  tags               = var.tags
}

data "aws_iam_policy_document" "empty" {
}

data "aws_iam_policy_document" "extended" {
  count = local.enabled ? 1 : 0

  source_json   = join("", data.aws_iam_policy_document.empty.*.json)
  override_json = var.extended_ec2_policy_document
}

resource "aws_iam_instance_profile" "ec2" {
  count = local.enabled ? 1 : 0

  name = "BioData-${var.elastic_beanstalk_environment_name}-eb-ec2-policy"
  role = join("", aws_iam_role.ec2.*.name)
  tags = var.tags
}

locals {
  # Remove `Name` tag from the map of tags because Elastic Beanstalk generates the `Name` tag automatically
  # and if it is provided, terraform tries to recreate the application on each `plan/apply`
  # `Namespace` should be removed as well since any string that contains `Name` forces recreation
  # https://github.com/terraform-providers/terraform-provider-aws/issues/3963
  tags = { for t in keys(var.tags) : t => var.tags[t] if t != "Name" && t != "Namespace" }

  classic_elb_settings = [
    {
      namespace = "aws:elb:loadbalancer"
      name      = "CrossZone"
      value     = var.loadbalancer_crosszone
    },
    {
      namespace = "aws:elb:loadbalancer"
      name      = "SecurityGroups"
      value     = join(",", sort(var.loadbalancer_security_groups))
    },
    {
      namespace = "aws:elb:loadbalancer"
      name      = "ManagedSecurityGroup"
      value     = var.loadbalancer_managed_security_group
    },
    {
      namespace = "aws:elb:listener"
      name      = "ListenerProtocol"
      value     = "HTTP"
    },
    {
      namespace = "aws:elb:listener"
      name      = "InstancePort"
      value     = var.application_port
    },
    {
      namespace = "aws:elb:listener"
      name      = "ListenerEnabled"
      value     = var.http_listener_enabled || var.loadbalancer_certificate_arn == "" ? "true" : "false"
    },
    {
      namespace = "aws:elb:listener:443"
      name      = "ListenerProtocol"
      value     = "HTTPS"
    },
    {
      namespace = "aws:elb:listener:443"
      name      = "InstancePort"
      value     = var.application_port
    },
    {
      namespace = "aws:elb:listener:443"
      name      = "SSLCertificateId"
      value     = var.loadbalancer_certificate_arn
    },
    {
      namespace = "aws:elb:listener:443"
      name      = "ListenerEnabled"
      value     = var.loadbalancer_certificate_arn == "" ? "false" : "true"
    },
    {
      namespace = "aws:elb:listener:${var.ssh_listener_port}"
      name      = "ListenerProtocol"
      value     = "TCP"
    },
    {
      namespace = "aws:elb:listener:${var.ssh_listener_port}"
      name      = "InstancePort"
      value     = "22"
    },
    {
      namespace = "aws:elb:listener:${var.ssh_listener_port}"
      name      = "ListenerEnabled"
      value     = var.ssh_listener_enabled
    },
    {
      namespace = "aws:elb:policies"
      name      = "ConnectionSettingIdleTimeout"
      value     = var.loadbalancer_connection_idle_timeout
    },
    {
      namespace = "aws:elb:policies"
      name      = "ConnectionDrainingEnabled"
      value     = "true"
    },
  ]

  generic_alb_settings = [
    {
      namespace = "aws:elbv2:loadbalancer"
      name      = "SecurityGroups"
      value     = join(",", sort(var.loadbalancer_security_groups))
    }
  ]

  shared_alb_settings = [
    {
      namespace = "aws:elasticbeanstalk:environment"
      name      = "LoadBalancerIsShared"
      value     = "true"
    },
    {
      namespace = "aws:elbv2:loadbalancer"
      name      = "SharedLoadBalancer"
      value     = var.shared_loadbalancer_arn
    }
  ]

  alb_settings = [
    #{
    #  namespace = "aws:elbv2:loadbalancer"
    #  name      = "AccessLogsS3Bucket"
    #  value     = !var.loadbalancer_is_shared ? join("", sort(aws_s3_bucket.elb_logs.*.id)) : ""
    #},
    #{
    #  namespace = "aws:elbv2:loadbalancer"
    #  name      = "AccessLogsS3Enabled"
    #  value     = "true"
    #},
    {
      namespace = "aws:elbv2:listener:default"
      name      = "ListenerEnabled"
      value     = var.http_listener_enabled || var.loadbalancer_certificate_arn == "" ? "true" : "false"
    },
    {
      namespace = "aws:elbv2:loadbalancer"
      name      = "ManagedSecurityGroup"
      value     = var.loadbalancer_managed_security_group
    },
    {
      namespace = "aws:elbv2:listener:443"
      name      = "ListenerEnabled"
      value     = var.loadbalancer_certificate_arn == "" ? "false" : "true"
    },
    {
      namespace = "aws:elbv2:listener:443"
      name      = "Protocol"
      value     = "HTTPS"
    },
    {
      namespace = "aws:elbv2:listener:443"
      name      = "SSLCertificateArns"
      value     = var.loadbalancer_certificate_arn
    },
    {
      namespace = "aws:elbv2:listener:443"
      name      = "SSLPolicy"
      value     = var.loadbalancer_type == "application" ? var.loadbalancer_ssl_policy : ""
    },
    ###===================== Application Load Balancer Health check settings =====================================================###
    # The Application Load Balancer health check does not take into account the Elastic Beanstalk health check path
    # http://docs.aws.amazon.com/elasticbeanstalk/latest/dg/environments-cfg-applicationloadbalancer.html
    # http://docs.aws.amazon.com/elasticbeanstalk/latest/dg/environments-cfg-applicationloadbalancer.html#alb-default-process.config
    {
      namespace = "aws:elasticbeanstalk:environment:process:default"
      name      = "HealthCheckPath"
      value     = var.healthcheck_url
    },
    {
      namespace = "aws:elasticbeanstalk:environment:process:default"
      name      = "MatcherHTTPCode"
      value     = join(",", sort(var.healthcheck_httpcodes_to_match))
    },
    {
      namespace = "aws:elasticbeanstalk:environment:process:default"
      name      = "HealthCheckTimeout"
      value     = var.healthcheck_timeout
    }
  ]

  nlb_settings = [
    {
      namespace = "aws:elbv2:listener:default"
      name      = "ListenerEnabled"
      value     = var.http_listener_enabled
    }
  ]

  # Settings for all loadbalancer types (including shared ALB)
  generic_elb_settings = [
    {
      namespace = "aws:elasticbeanstalk:environment"
      name      = "LoadBalancerType"
      value     = var.loadbalancer_type
    }
  ]

  # Settings for beanstalk managed elb only (so not for shared ALB)
  beanstalk_elb_settings = [
    {
      namespace = "aws:ec2:vpc"
      name      = "ELBSubnets"
      value     = join(",", sort(var.loadbalancer_subnets))
    },
    {
      namespace = "aws:elasticbeanstalk:environment:process:default"
      name      = "Port"
      value     = var.application_port
    },
    {
      namespace = "aws:elasticbeanstalk:environment:process:default"
      name      = "Protocol"
      value     = var.loadbalancer_type == "network" ? "TCP" : "HTTP"
    },
    {
      namespace = "aws:ec2:vpc"
      name      = "ELBScheme"
      value     = var.environment_type == "LoadBalanced" ? var.elb_scheme : ""
    },
    {
      namespace = "aws:elasticbeanstalk:environment:process:default"
      name      = "HealthCheckInterval"
      value     = var.healthcheck_interval
    },
    {
      namespace = "aws:elasticbeanstalk:environment:process:default"
      name      = "HealthyThresholdCount"
      value     = var.healthcheck_healthy_threshold_count
    },
    {
      namespace = "aws:elasticbeanstalk:environment:process:default"
      name      = "UnhealthyThresholdCount"
      value     = var.healthcheck_unhealthy_threshold_count
    }
  ]

  # Select elb configuration depending on loadbalancer_type
  elb_settings_nlb        = var.loadbalancer_type == "network" ? concat(local.nlb_settings, local.generic_elb_settings, local.beanstalk_elb_settings) : []
  elb_settings_alb        = var.loadbalancer_type == "application" && !var.loadbalancer_is_shared ? concat(local.alb_settings, local.generic_alb_settings, local.generic_elb_settings, local.beanstalk_elb_settings) : []
  elb_settings_shared_alb = var.loadbalancer_type == "application" && var.loadbalancer_is_shared ? concat(local.shared_alb_settings, local.generic_alb_settings, local.generic_elb_settings) : []
  elb_setting_classic     = var.loadbalancer_type == "classic" ? concat(local.classic_elb_settings, local.generic_elb_settings, local.beanstalk_elb_settings) : []

  # If the tier is "WebServer" add the elb_settings, otherwise exclude them
  elb_settings_final = var.tier == "WebServer" ? concat(local.elb_settings_nlb, local.elb_settings_alb, local.elb_settings_shared_alb, local.elb_setting_classic) : []
}

#
# Full list of options:
# http://docs.aws.amazon.com/elasticbeanstalk/latest/dg/command-options-general.html#command-options-general-elasticbeanstalkmanagedactionsplatformupdate
#
resource "aws_elastic_beanstalk_environment" "default" {
  count = local.enabled ? 1 : 0

  name                   = var.elastic_beanstalk_environment_name
  application            = var.elastic_beanstalk_application_name
  description            = var.description
  tier                   = var.tier
  solution_stack_name    = var.solution_stack_name
  wait_for_ready_timeout = var.wait_for_ready_timeout
  version_label          = var.version_label
  tags                   = local.tags

  dynamic "setting" {
    for_each = local.elb_settings_final
    content {
      namespace = setting.value["namespace"]
      name      = setting.value["name"]
      value     = setting.value["value"]
      resource  = ""
    }
  }

  setting {
    namespace = "aws:ec2:vpc"
    name      = "VPCId"
    value     = var.vpc_id
    resource  = ""
  }

  setting {
    namespace = "aws:ec2:vpc"
    name      = "AssociatePublicIpAddress"
    value     = var.associate_public_ip_address
    resource  = ""
  }

  setting {
    namespace = "aws:ec2:vpc"
    name      = "Subnets"
    value     = join(",", sort(var.application_subnets))
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "SecurityGroups"
    value     = join(",", compact(sort(var.associated_security_group_ids)))
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     = join("", aws_iam_instance_profile.ec2.*.name)
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:asg"
    name      = "Availability Zones"
    value     = var.availability_zone_selector
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "EnvironmentType"
    value     = var.environment_type
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "ServiceRole"
    value     = join("", aws_iam_role.service.*.arn)
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "BASE_HOST"
    value     = var.elastic_beanstalk_environment_name
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:healthreporting:system"
    name      = "SystemType"
    value     = var.enhanced_reporting_enabled ? "enhanced" : "basic"
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions"
    name      = "ManagedActionsEnabled"
    value     = var.managed_actions_enabled ? "true" : "false"
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:asg"
    name      = "MinSize"
    value     = var.autoscale_min
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:asg"
    name      = "MaxSize"
    value     = var.autoscale_max
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:asg"
    name      = "EnableCapacityRebalancing"
    value     = var.enable_capacity_rebalancing
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:updatepolicy:rollingupdate"
    name      = "RollingUpdateEnabled"
    value     = var.rolling_update_enabled
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:updatepolicy:rollingupdate"
    name      = "RollingUpdateType"
    value     = var.rolling_update_type
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:updatepolicy:rollingupdate"
    name      = "MinInstancesInService"
    value     = var.updating_min_in_service
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "DeploymentPolicy"
    value     = var.deployment_policy
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:updatepolicy:rollingupdate"
    name      = "MaxBatchSize"
    value     = var.updating_max_batch
    resource  = ""
  }

  setting {
    namespace = "aws:ec2:instances"
    name      = "InstanceTypes"
    value     = var.instance_type
    resource  = ""
  }

  setting {
    namespace = "aws:ec2:instances"
    name      = "EnableSpot"
    value     = var.enable_spot_instances ? "true" : "false"
    resource  = ""
  }

  setting {
    namespace = "aws:ec2:instances"
    name      = "SpotFleetOnDemandBase"
    value     = var.spot_fleet_on_demand_base
    resource  = ""
  }

  setting {
    namespace = "aws:ec2:instances"
    name      = "SpotFleetOnDemandAboveBasePercentage"
    value     = var.spot_fleet_on_demand_above_base_percentage == -1 ? (var.environment_type == "LoadBalanced" ? 70 : 0) : var.spot_fleet_on_demand_above_base_percentage
    resource  = ""
  }

  setting {
    namespace = "aws:ec2:instances"
    name      = "SpotMaxPrice"
    value     = var.spot_max_price == -1 ? "" : var.spot_max_price
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "EC2KeyName"
    value     = var.keypair
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "RootVolumeSize"
    value     = var.root_volume_size
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "RootVolumeType"
    value     = var.root_volume_type
    resource  = ""
  }

  dynamic "setting" {
    for_each = var.root_volume_throughput == null ? [] : [var.root_volume_throughput]
    content {
      namespace = "aws:autoscaling:launchconfiguration"
      name      = "RootVolumeThroughput"
      value     = setting.value
      resource  = ""
    }
  }

  dynamic "setting" {
    for_each = var.root_volume_iops == null ? [] : [var.root_volume_iops]
    content {
      namespace = "aws:autoscaling:launchconfiguration"
      name      = "RootVolumeIOPS"
      value     = setting.value
      resource  = ""
    }
  }

  dynamic "setting" {
    for_each = var.ami_id == null ? [] : [var.ami_id]
    content {
      namespace = "aws:autoscaling:launchconfiguration"
      name      = "ImageId"
      value     = setting.value
      resource  = ""
    }
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "BatchSizeType"
    value     = var.deployment_batch_size_type
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "BatchSize"
    value     = var.deployment_batch_size
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "IgnoreHealthCheck"
    value     = var.deployment_ignore_health_check
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:command"
    name      = "Timeout"
    value     = var.deployment_timeout
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions"
    name      = "PreferredStartTime"
    value     = var.preferred_start_time
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions:platformupdate"
    name      = "UpdateLevel"
    value     = var.update_level
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:managedactions:platformupdate"
    name      = "InstanceRefreshEnabled"
    value     = var.instance_refresh_enabled
    resource  = ""
  }

  ###=========================== Autoscale trigger ========================== ###

  setting {
    namespace = "aws:autoscaling:trigger"
    name      = "MeasureName"
    value     = var.autoscale_measure_name
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:trigger"
    name      = "Statistic"
    value     = var.autoscale_statistic
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:trigger"
    name      = "Unit"
    value     = var.autoscale_unit
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:trigger"
    name      = "LowerThreshold"
    value     = var.autoscale_lower_bound
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:trigger"
    name      = "LowerBreachScaleIncrement"
    value     = var.autoscale_lower_increment
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:trigger"
    name      = "UpperThreshold"
    value     = var.autoscale_upper_bound
    resource  = ""
  }

  setting {
    namespace = "aws:autoscaling:trigger"
    name      = "UpperBreachScaleIncrement"
    value     = var.autoscale_upper_increment
    resource  = ""
  }

  ###=========================== Scheduled Actions ========================== ###

  dynamic "setting" {
    for_each = var.scheduled_actions
    content {
      namespace = "aws:autoscaling:scheduledaction"
      name      = "MinSize"
      value     = setting.value.minsize
      resource  = setting.value.name
    }
  }
  dynamic "setting" {
    for_each = var.scheduled_actions
    content {
      namespace = "aws:autoscaling:scheduledaction"
      name      = "MaxSize"
      value     = setting.value.maxsize
      resource  = setting.value.name
    }
  }
  dynamic "setting" {
    for_each = var.scheduled_actions
    content {
      namespace = "aws:autoscaling:scheduledaction"
      name      = "DesiredCapacity"
      value     = setting.value.desiredcapacity
      resource  = setting.value.name
    }
  }
  dynamic "setting" {
    for_each = var.scheduled_actions
    content {
      namespace = "aws:autoscaling:scheduledaction"
      name      = "Recurrence"
      value     = setting.value.recurrence
      resource  = setting.value.name
    }
  }
  dynamic "setting" {
    for_each = var.scheduled_actions
    content {
      namespace = "aws:autoscaling:scheduledaction"
      name      = "StartTime"
      value     = setting.value.starttime
      resource  = setting.value.name
    }
  }
  dynamic "setting" {
    for_each = var.scheduled_actions
    content {
      namespace = "aws:autoscaling:scheduledaction"
      name      = "EndTime"
      value     = setting.value.endtime
      resource  = setting.value.name
    }
  }
  dynamic "setting" {
    for_each = var.scheduled_actions
    content {
      namespace = "aws:autoscaling:scheduledaction"
      name      = "Suspend"
      value     = setting.value.suspend ? "true" : "false"
      resource  = setting.value.name
    }
  }


  ###=========================== Logging ========================== ###

  setting {
    namespace = "aws:elasticbeanstalk:hostmanager"
    name      = "LogPublicationControl"
    value     = var.enable_log_publication_control ? "true" : "false"
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:cloudwatch:logs"
    name      = "StreamLogs"
    value     = var.enable_stream_logs ? "true" : "false"
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:cloudwatch:logs"
    name      = "DeleteOnTerminate"
    value     = var.logs_delete_on_terminate ? "true" : "false"
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:cloudwatch:logs"
    name      = "RetentionInDays"
    value     = var.logs_retention_in_days
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:cloudwatch:logs:health"
    name      = "HealthStreamingEnabled"
    value     = var.health_streaming_enabled ? "true" : "false"
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:cloudwatch:logs:health"
    name      = "DeleteOnTerminate"
    value     = var.health_streaming_delete_on_terminate ? "true" : "false"
    resource  = ""
  }

  setting {
    namespace = "aws:elasticbeanstalk:cloudwatch:logs:health"
    name      = "RetentionInDays"
    value     = var.health_streaming_retention_in_days
    resource  = ""
  }

  # Add additional Elastic Beanstalk settings
  # For full list of options, see https://docs.aws.amazon.com/elasticbeanstalk/latest/dg/command-options-general.html
  dynamic "setting" {
    for_each = var.additional_settings
    content {
      namespace = setting.value.namespace
      name      = setting.value.name
      value     = setting.value.value
      resource  = ""
    }
  }

  # dynamic needed as "spot max price" should only have a value if it is defined.
  dynamic "setting" {
    for_each = var.spot_max_price == -1 ? [] : [var.spot_max_price]
    content {
      namespace = "aws:ec2:instances"
      name      = "SpotMaxPrice"
      value     = var.spot_max_price
      resource  = ""
    }
  }

  # Add environment variables if provided
  dynamic "setting" {
    for_each = var.env_vars
    content {
      namespace = "aws:elasticbeanstalk:application:environment"
      name      = setting.key
      value     = setting.value
      resource  = ""
    }
  }
}

data "aws_elb_service_account" "main" {
  count = local.enabled && var.tier == "WebServer" && var.environment_type == "LoadBalanced" ? 1 : 0
}

data "aws_iam_policy_document" "elb_logs" {
  count = local.enabled && var.tier == "WebServer" && var.environment_type == "LoadBalanced" && var.loadbalancer_type != "network" && !var.loadbalancer_is_shared ? 1 : 0

  statement {
    sid = ""

    actions = [
      "s3:PutObject",
    ]

    resources = [
      "arn:${local.partition}:s3:::${var.elastic_beanstalk_environment_name}-eb-loadbalancer-logs/*"
    ]

    principals {
      type        = "AWS"
      identifiers = [join("", data.aws_elb_service_account.main.*.arn)]
    }

    effect = "Allow"
  }
}

resource "aws_s3_bucket" "elb_logs" {
  #bridgecrew:skip=BC_AWS_S3_13:Skipping `Enable S3 Bucket Logging` check until bridgecrew will support dynamic blocks (https://github.com/bridgecrewio/checkov/issues/776).
  #bridgecrew:skip=BC_AWS_S3_14:Skipping `Ensure all data stored in the S3 bucket is securely encrypted at rest` check until bridgecrew will support dynamic blocks (https://github.com/bridgecrewio/checkov/issues/776).
  #bridgecrew:skip=CKV_AWS_52:Skipping `Ensure S3 bucket has MFA delete enabled` due to issue in terraform (https://github.com/hashicorp/terraform-provider-aws/issues/629).
  #bridgecrew:skip=BC_AWS_S3_16:Skipping since adding count condition sounds like to trigger an error. (https://github.com/cloudposse/terraform-aws-elastic-beanstalk-environment/pull/182)
  #bridgecrew:skip=BC_AWS_GENERAL_56:Skipping "Ensure S3 buckets are encrypted with KMS by default"
  #bridgecrew:skip=BC_AWS_NETWORKING_52:Skipping "Ensure S3 Bucket has public access blocks"
  #bridgecrew:skip=BC_AWS_GENERAL_72:Skipping "Ensure S3 bucket has cross-region replication enabled"
  count         = 0
  bucket        = "${var.elastic_beanstalk_environment_name}-eb-loadbalancer-logs"
  acl           = "private"
  force_destroy = var.force_destroy
  policy        = join("", data.aws_iam_policy_document.elb_logs.*.json)
  tags          = var.tags

  dynamic "server_side_encryption_configuration" {
    for_each = var.s3_bucket_encryption_enabled ? ["true"] : []

    content {
      rule {
        apply_server_side_encryption_by_default {
          sse_algorithm = "AES256"
        }
      }
    }
  }

  versioning {
    enabled = var.s3_bucket_versioning_enabled
  }

  dynamic "logging" {
    for_each = var.s3_bucket_access_log_bucket_name != "" ? [1] : []
    content {
      target_bucket = var.s3_bucket_access_log_bucket_name
      target_prefix = "logs/${var.elastic_beanstalk_environment_name}/"
    }
  }
}

data "aws_region" "current" {}


locals {
  name                = "${replace(var.vpc_name, "/[^a-zA-Z0-9_\\-\\.]/", "")}-${var.label}"
  tags                = tolist(setunion(var.tags, [var.label]))
  base_security_group = var.base_security_group != null ? var.base_security_group : data.ibm_is_vpc.vpc.default_security_group
  ssh_security_group_rule = var.allow_ssh_from != "" ? [{
    name      = "ssh-inbound"
    direction = "inbound"
    remote    = var.allow_ssh_from
    tcp = {
      port_min = 22
      port_max = 22
    }
  }] : []
  internal_network_rules = [{
    name      = "services-outbound"
    direction = "outbound"
    remote    = "166.8.0.0/14"
  }, {
    name      = "adn-dns-outbound"
    direction = "outbound"
    remote    = "161.26.0.0/16"
    udp = {
      port_min = 53
      port_max = 53
    }
  }, {
    name      = "adn-http-outbound"
    direction = "outbound"
    remote    = "161.26.0.0/16"
    tcp = {
      port_min = 80
      port_max = 80
    }
  }, {
    name      = "adn-https-outbound"
    direction = "outbound"
    remote    = "161.26.0.0/16"
    tcp = {
      port_min = 443
      port_max = 443
    }
  }]
  security_group_rules = concat(local.ssh_security_group_rule, var.security_group_rules, local.internal_network_rules)
}

resource null_resource print_names {
  provisioner "local-exec" {
    command = "echo 'VPC name: ${var.vpc_name}'"
  }
}

data ibm_is_image image {
  name = var.image_name
}

resource null_resource print_deprecated {
  provisioner "local-exec" {
    command = "${path.module}/scripts/check-image.sh '${data.ibm_is_image.image.status}' '${data.ibm_is_image.image.name}' '${var.allow_deprecated_image}'"
  }
}

data ibm_is_vpc vpc {
  depends_on = [null_resource.print_names]

  name  = var.vpc_name
}

resource ibm_is_security_group vsi {
  name           = "${local.name}-group"
  vpc            = data.ibm_is_vpc.vpc.id
  resource_group = var.resource_group_id
}

resource ibm_is_security_group_rule additional_rules {
  count = length(local.security_group_rules)

  group      = ibm_is_security_group.vsi.id
  direction  = local.security_group_rules[count.index]["direction"]
  remote     = lookup(local.security_group_rules[count.index], "remote", null)
  ip_version = lookup(local.security_group_rules[count.index], "ip_version", null)

  dynamic "tcp" {
    for_each = lookup(local.security_group_rules[count.index], "tcp", null) != null ? [ lookup(local.security_group_rules[count.index], "tcp", null) ] : []

    content {
      port_min = tcp.value["port_min"]
      port_max = tcp.value["port_max"]
    }
  }

  dynamic "udp" {
    for_each = lookup(local.security_group_rules[count.index], "udp", null) != null ? [ lookup(local.security_group_rules[count.index], "udp", null) ] : []

    content {
      port_min = udp.value["port_min"]
      port_max = udp.value["port_max"]
    }
  }

  dynamic "icmp" {
    for_each = lookup(local.security_group_rules[count.index], "icmp", null) != null ? [ lookup(local.security_group_rules[count.index], "icmp", null) ] : []

    content {
      type = icmp.value["type"]
      code = lookup(icmp.value, "code", null)
    }
  }
}

resource null_resource print_key_crn {
  count = var.kms_enabled ? 1 : 0

  provisioner "local-exec" {
    command = "echo 'Key crn: ${var.kms_key_crn == null ? "null" : var.kms_key_crn}'"
  }
}

data ibm_is_subnet subnet {
  count = var.vpc_subnet_count > 0 ? 1 : 0

  identifier = var.vpc_subnets[0].id
}

resource null_resource update_acl_rules {
  count = var.vpc_subnet_count > 0 && (length(var.acl_rules) > 0 || length(local.security_group_rules) > 0) ? 1 : 0

  provisioner "local-exec" {
    command = "${path.module}/scripts/setup-acl-rules.sh '${data.ibm_is_subnet.subnet[0].network_acl}' '${var.region}' '${var.resource_group_id}' '${var.target_network_range}'"

    environment = {
      IBMCLOUD_API_KEY = var.ibmcloud_api_key
      ACL_RULES        = jsonencode(var.acl_rules)
      SG_RULES         = jsonencode(local.security_group_rules)
    }
  }
}

resource ibm_is_instance vsi {
  depends_on = [null_resource.print_key_crn, null_resource.print_deprecated, ibm_is_security_group_rule.additional_rules, null_resource.update_acl_rules]
  count = var.vpc_subnet_count

  name           = "${local.name}${format("%02s", count.index)}"
  vpc            = data.ibm_is_vpc.vpc.id
  zone           = var.vpc_subnets[count.index].zone
  profile        = var.profile_name
  image          = data.ibm_is_image.image.id
  keys           = tolist(setsubtract([var.ssh_key_id], [""]))
  resource_group = var.resource_group_id
  auto_delete_volume = var.auto_delete_volume

  user_data = var.init_script != "" ? var.init_script : file("${path.module}/scripts/init-script-ubuntu.sh")

  primary_network_interface {
    subnet          = var.vpc_subnets[count.index].id
    #security_groups = [local.base_security_group, ibm_is_security_group.vsi.id]
    name            = var.primary_network_interface_name
  }

  boot_volume {
    name       = "${local.name}${format("%02s", count.index)}-boot"
    encryption = var.kms_enabled ? var.kms_key_crn : null
  }

  tags = var.tags
}

resource ibm_is_floating_ip vsi {
  count = var.create_public_ip ? var.vpc_subnet_count : 0

  name           = "${local.name}${format("%02s", count.index)}-ip"
  target         = ibm_is_instance.vsi[count.index].primary_network_interface[0].id
  resource_group = var.resource_group_id

  tags = var.tags
}

#resource ibm_is_security_group_rule ssh_to_self_public_ip {
#  count = var.create_public_ip ? var.vpc_subnet_count : 0

#  group     = ibm_is_security_group.vsi.id
#  direction = "outbound"
#  remote    = ibm_is_floating_ip.vsi[count.index].address
#  tcp {
#    port_min = 22
#    port_max = 22
#  }
#}

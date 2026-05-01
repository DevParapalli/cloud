terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

provider "oci" {
  region              = "ap-hyderabad-1"
  auth                = "SecurityToken"
  config_file_profile = "terraform"
}

locals {
  compartment_id = "ocid1.tenancy.oc1..aaaaaaaarc3hplbpaeenwm4n2yauexgllinjqkaaqxrkdkgr7i2pxgjkjk6q"

  ubuntu_image_id = "ocid1.image.oc1.ap-hyderabad-1.aaaaaaaakismgoshenczkdzz6wo3xasexwyftnxuu6ip6o23x4vg5cc2b3ja"
}

variable "copyparty_password" {
  sensitive = true
}

# ── Images ────────────────────────────────────────────────────────────────────

data "oci_core_images" "ubuntu_latest" {
  compartment_id           = local.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ── VCN ───────────────────────────────────────────────────────────────────────

resource "oci_core_vcn" "vcn_devparapalli" {
  dns_label      = "internal"
  cidr_block     = "10.0.0.0/16"
  compartment_id = local.compartment_id
  display_name   = "vcn_devparapalli"
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "oci_core_internet_gateway" "igw" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.vcn_devparapalli.id
  display_name   = "igw_devparapalli"
  enabled        = true
}

# ── Route Table ───────────────────────────────────────────────────────────────

resource "oci_core_route_table" "rt" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.vcn_devparapalli.id
  display_name   = "rt_devparapalli"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

# ── Security List ─────────────────────────────────────────────────────────────
# Opens: SSH (22), copyparty default HTTP (3000), HTTPS (443)
# Remove any ports you don't need.

resource "oci_core_security_list" "sl" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.vcn_devparapalli.id
  display_name   = "sl_devparapalli"

  # Allow all outbound traffic
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Soft Serve SSH
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 23231
      max = 23231
    }
  }


  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }


  # HTTPS
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }
}

# ── Subnet ────────────────────────────────────────────────────────────────────

resource "oci_core_subnet" "subnet_vcn_devparapalli" {
  cidr_block        = "10.0.1.0/24"
  compartment_id    = local.compartment_id
  vcn_id            = oci_core_vcn.vcn_devparapalli.id
  display_name      = "subnet_vcn_devparapalli"
  route_table_id    = oci_core_route_table.rt.id
  security_list_ids = [oci_core_security_list.sl.id]
  dns_label         = "subnet1"
}

# ── Instance ──────────────────────────────────────────────────────────────────

resource "oci_core_instance" "copyparty" {
  availability_domain = "chdz:AP-HYDERABAD-1-AD-1"
  compartment_id      = local.compartment_id
  shape               = "VM.Standard.A1.Flex"
  display_name        = "cppty-softsrv-srv-primary"

  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet_vcn_devparapalli.id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = file("${path.module}/oci_key.pub")
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      cf_cert      = file("${path.module}/origin.pem")
      cf_key       = file("${path.module}/origin.key")
      cpp_password = var.copyparty_password
      soft_serve_admin_key = trimspace(file("${path.module}/oci_key.pub"))
    }))
  }

  source_details {
    boot_volume_size_in_gbs = 50
    boot_volume_vpus_per_gb = 10
    source_type             = "image"
    source_id               = local.ubuntu_image_id
  }
}

# ── Block Volume ──────────────────────────────────────────────────────────────

resource "oci_core_volume" "data" {
  compartment_id      = local.compartment_id
  availability_domain = "chdz:AP-HYDERABAD-1-AD-1"
  display_name        = "data-volume"
  size_in_gbs         = 120 # adjust as needed, OCI free tier includes 200GB total
  vpus_per_gb         = 10
}

resource "oci_core_volume_attachment" "data_attach" {
  attachment_type                     = "paravirtualized"
  instance_id                         = oci_core_instance.copyparty.id
  volume_id                           = oci_core_volume.data.id
  display_name                        = "data-volume-attach"
  is_pv_encryption_in_transit_enabled = false
}




# ── Outputs ───────────────────────────────────────────────────────────────────

output "data_volume_id" {
  value = oci_core_volume.data.id
}

output "instance_public_ip" {
  value = oci_core_instance.copyparty.public_ip
}

output "latest_ubuntu_image_id" {
  value = data.oci_core_images.ubuntu_latest.images[0].id
}
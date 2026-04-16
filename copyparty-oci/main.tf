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
  vcn_id            = oci_core_vcn.vcn_devparapalli.id # FIX: was a bare string
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
  display_name        = "copyparty-instance"

  shape_config {
    ocpus         = 1
    memory_in_gbs = 6
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.subnet_vcn_devparapalli.id
    assign_public_ip = true
  }

  metadata = {
    ssh_authorized_keys = file("${path.module}/oci_key.pub")
  }

  source_details {
    boot_volume_size_in_gbs = 100
    boot_volume_vpus_per_gb = 10
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_latest.images[0].id
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "instance_public_ip" {
  value = oci_core_instance.copyparty.public_ip
}

provider "azurerm" {
  features {}
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

locals {
  key_name = "${var.organization_name}-${random_string.suffix.result}"
}

resource "azurerm_resource_group" "jys" {
  name     = local.key_name
  location = "West US"
}

resource "tls_private_key" "pk" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_sensitive_file" "private_key" {
  content  = tls_private_key.pk.private_key_pem
  filename = "${local.key_name}.pem"

  provisioner "local-exec" {
    command = "chmod 400 ${self.filename}"
  }
}


resource "azurerm_public_ip" "eip" {
  count               = 3
  name                = "public_ip${count.index}"
  location            = azurerm_resource_group.jys.location
  resource_group_name = azurerm_resource_group.jys.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_virtual_network" "main" {
  name                = "jys-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.jys.location
  resource_group_name = azurerm_resource_group.jys.name
}

resource "azurerm_subnet" "internal" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.jys.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_network_security_group" "jys" {
  name                = "${local.key_name}-security-group"
  location            = azurerm_resource_group.jys.location
  resource_group_name = azurerm_resource_group.jys.name

  security_rule {
    name                       = "SSH"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTP"
    priority                   = 320
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTPS"
    priority                   = 340
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

}

resource "azurerm_network_interface" "main" {
  count               = 3
  name                = "nic${count.index}"
  location            = azurerm_resource_group.jys.location
  resource_group_name = azurerm_resource_group.jys.name

  ip_configuration {
    name                          = "ipconfig${count.index}"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.eip[count.index].id
  }
  depends_on = [ azurerm_network_security_group.jys ]
}

resource "azurerm_subnet_network_security_group_association" "subnet_sec" {
  subnet_id                 = azurerm_subnet.internal.id
  network_security_group_id = azurerm_network_security_group.jys.id
}

resource "azurerm_virtual_machine" "main" {
  count                = 3
  name                 = "${local.key_name}-vm${count.index}"
  location             = azurerm_resource_group.jys.location
  resource_group_name  = azurerm_resource_group.jys.name
  network_interface_ids = [azurerm_network_interface.main[count.index].id]
  vm_size              = var.vm_size

  delete_os_disk_on_termination   = true
  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }

  storage_os_disk {
    name              = "myosdisk${count.index}"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
    disk_size_gb      = 50
  }

  os_profile {
    computer_name  = "hostname${count.index}"
    admin_username = var.admin_username
    custom_data = base64encode(<<EOF
#!/bin/bash
sudo mkdir -p /root/.ssh/
sudo cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/
sudo chmod 700 /root/.ssh
sudo chmod 600 /root/.ssh/authorized_keys
EOF
    )
  }

  os_profile_linux_config {
    ssh_keys {
      path     = "/home/${var.admin_username}/.ssh/authorized_keys"
      key_data = tls_private_key.pk.public_key_openssh
    }
    disable_password_authentication = true
  }

  tags = {
    environment = "staging"
  }
}

resource "azurerm_managed_disk" "additional_disks" {
  count                = 3
  name                 = "${local.key_name}-disk${count.index}"
  location             = azurerm_resource_group.jys.location
  resource_group_name  = azurerm_resource_group.jys.name
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = "50"
}

resource "azurerm_virtual_machine_data_disk_attachment" "disk" {
  count              = 3
  managed_disk_id    = azurerm_managed_disk.additional_disks[count.index].id
  virtual_machine_id = azurerm_virtual_machine.main[count.index].id
  lun                = "50"
  caching            = "ReadWrite"
}

resource "null_resource" "bash_command" {
  provisioner "local-exec" {
      command =  "printf 'root@${azurerm_public_ip.eip[0].ip_address}\nroot@${azurerm_public_ip.eip[1].ip_address}\nroot@${azurerm_public_ip.eip[2].ip_address}\n' > ./eip "
  }
}


output "instance_public_ips" {
  description = "The public IP addresses of all the instances"
  value       = azurerm_public_ip.eip[*].ip_address
}

resource "aws_vpc" "vpc" {

  cidr_block = "10.1.0.0/16"

  tags = {
    Name = "${var.name}-${var.region}-vpc"
  }

}

// aws recommends /19

resource "aws_subnet" "a-1" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}a"
  cidr_block        = "10.1.0.0/19"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name}-${var.region}a"
  }
}

resource "aws_subnet" "b-1" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}b"
  cidr_block        = "10.1.32.0/19"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name}-${var.region}b"
  }
}


resource "aws_subnet" "c-1" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}c"
  cidr_block        = "10.1.64.0/19"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name}-${var.region}c"
  }
}


resource "aws_internet_gateway" "ig" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "${var.name}-ig"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ig.id
  }

  tags = {
    Name = "${var.name}-public"
  }
}

resource "aws_route_table_association" "a_public" {
  subnet_id      = aws_subnet.a-1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "b_public" {
  subnet_id      = aws_subnet.b-1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "c_public" {
  subnet_id      = aws_subnet.c-1.id
  route_table_id = aws_route_table.public.id
}

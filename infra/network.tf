resource "aws_vpc" "vpc" {

  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "${var.name}-vpc"
  }

}

resource "aws_subnet" "s_1a-1" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}-1a"
  cidr_block        = "10.1.0.0/16"

  tags = {
    Name = "${var.name}-1a-1"
  }
}

resource "aws_subnet" "s_1a-2" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}-1a"
  cidr_block        = "10.2.0.0/16"

  tags = {
    Name = "${var.name}-1a-2"
  }
}


resource "aws_subnet" "s_1b-1" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}-1b"
  cidr_block        = "10.3.0.0/16"

  tags = {
    Name = "${var.name}-1b-1"
  }
}

resource "aws_subnet" "s_1b-2" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}-1b"
  cidr_block        = "10.4.0.0/16"

  tags = {
    Name = "${var.name}-1b-2"
  }
}


resource "aws_subnet" "s_1c-1" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}-1c"
  cidr_block        = "10.5.0.0/16"

  tags = {
    Name = "${var.name}-1c-1"
  }
}

resource "aws_subnet" "s_1c-2" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}-1c"
  cidr_block        = "10.6.0.0/16"

  tags = {
    Name = "${var.name}-1c-2"
  }
}


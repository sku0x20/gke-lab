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

  tags = {
    Name = "${var.name}-${var.region}a"
  }
}

resource "aws_subnet" "b-1" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}b"
  cidr_block        = "10.1.32.0/19"

  tags = {
    Name = "${var.name}-${var.region}b"
  }
}


resource "aws_subnet" "c-1" {
  vpc_id            = aws_vpc.vpc.id
  availability_zone = "${var.region}c"
  cidr_block        = "10.1.64.0/19"

  tags = {
    Name = "${var.name}-${var.region}c"
  }
}

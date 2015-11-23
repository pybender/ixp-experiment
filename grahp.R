setwd('/home/trungth/git/ixp-lab')
data <- read.csv(file='results.txt', sep="\t", fill=TRUE, header=TRUE)

boxplot(data, varwidth=TRUE, ylab ="Convergence Time (s)", xlab ="Number of Member ASes")
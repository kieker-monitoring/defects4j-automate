
calc_paired_t() {
    values=$(awk '
    BEGIN {
        sum = 0;
        sum_sq = 0;
        n = 0;
    }
    {
        d = $1;
        sum += d;
        sum_sq += d * d;
        n++;
    }
    END {
        if (n < 2) {
            print "N zu klein";
            exit;
        }
        
        mean_d = sum / n;
        var_d = (sum_sq - (sum * sum / n)) / (n - 1);
        
        if (var_d <= 0) {
            print "t = 0 (Keine Varianz)";
            exit;
        }
        
        sd_d = sqrt(var_d);
        se_d = sd_d / sqrt(n);
        t_stat = mean_d / se_d;
        df = n - 1;
        cohen_d = t_stat / sqrt(n);

        printf "N=%d Mean_Diff=%.4f SD_Diff=%.4f df=%d t=%.3f d=%.3f\n", n, mean_d, sd_d, df, t_stat, cohen_d;
    }')
    echo -n "$values "
    t_stat=$(echo $values | awk '{print $5}' | cut -d'=' -f2)
    df=$(echo $values | awk '{print $4}' | cut -d'=' -f2)
    p_value=$(Rscript -e 'cat(sprintf("%.4f", 2 * pt(-abs('$t_stat'), df = '$df')))')
    echo "p=$p_value"
}

project=$1

echo -n "Uninformed vs. Semi-informed: "
for bugid in $(cat iteration-0/bugs_"$project"_uninformed.txt | awk '{if ($2==1) print $1}'); do
	for i in {0..7}; do
		grep "^$bugid " iteration-$i/bugs_"$project"_uninformed.txt
	done | awk 'BEGIN {fixed=0;} {if ($3 == 0) fixed++; if ($2 == 1) overall++;} END {print fixed/overall}' | tr "\n" " "
	
	for i in {0..7}; do
		grep "^$bugid " iteration-$i/bugs_"$project"_semi-informed.txt
	done | awk 'BEGIN {fixed=0;} {if ($3 == 0) fixed++; if ($2 == 1) overall++;} END {print fixed/overall}'
done | awk '{print $1-$2}' | calc_paired_t

echo -n "Uninformed vs. informed: "
for bugid in $(cat iteration-0/bugs_"$project"_uninformed.txt | awk '{if ($2==1) print $1}'); do
	for i in {0..7}; do
		grep "^$bugid " iteration-$i/bugs_"$project"_uninformed.txt
	done | awk 'BEGIN {fixed=0;} {if ($3 == 0) fixed++; if ($2 == 1) overall++;} END {print fixed/overall}' | tr "\n" " "
	
	for i in {0..7}; do
		grep "^$bugid " iteration-$i/bugs_"$project"_informed.txt
	done | awk 'BEGIN {fixed=0;} {if ($3 == 0) fixed++; if ($2 == 1) overall++;} END {print fixed/overall}'
done | awk '{print $1-$2}' | calc_paired_t

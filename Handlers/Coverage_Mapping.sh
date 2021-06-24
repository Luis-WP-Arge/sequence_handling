#!/bin/bash

set -o pipefail

#   What are the dependencies for Coverage_Mapping?
declare -a Coverage_Mapping_Dependencies=(bedtools parallel)

#   Makes the outdirectories
# function makeOutDirectories() {
#     local outPrefix="$1"
#     mkdir -p "${outPrefix}"/Histograms
#     mkdir -p "${outPrefix}"/Plots
# }

# export -f makeOutDirectories

#   A function to plot the coverage - DEPRICATED, might be added back later
# function plotCoverage() {
#     local sample="$1" # Figure out what this sample is
#     local out="$2" # Where do we store our output files?
#     local sequenceHandling="$3" # Where is sequence_handling?
#     local helperScripts="${sequenceHandling}"/HelperScripts
#     local name="$(basename ${sample} .coverage.hist.txt)" # Get the name of the sample
#     Rscript "${helperScripts}"/plot_cov.R "${sample}" "${out}" "${name}" "${sequenceHandling}"
# }

# export -f plotCoverage

# Check if .hist file was successfully generated
function check_hist() {
    local filepath="$1"
    if ! [[ -f ${filepath} ]]; then
        echo "Failed to generate ${filepath} file, exiting..."
        exit 1
    fi
}

export -f check_hist

#   This is to calculate histograms and summary statistics for exome capture data
function EC_Coverage() {
    local bam_file="$1"
    local region_file="$2"
    local out_dir="$3"
    local project="$4"
    local olderBedtools="$5"
    local bam_dir=$(dirname "${bam_file}")
    set -x # for debugging, delete later
    #   Get the sample name without the .bam
    local sampleName=$(basename "${bam_file}" .bam)
    #   Generate coverage histograms as text files
    if [[ ${olderBedtools} == "true" ]]; then
	    bedtools coverage -hist -abam "${bam_file}" -b "${region_file}" > ${out_dir}/Histograms/${sampleName}.hist
    else
        # with bedtools version 2.24.0 or newer
	    bedtools coverage -hist -a "${region_file}" -b "${bam_file}" > ${out_dir}/Histograms/${sampleName}.hist
    fi
    #   Check if .hist file was successfully generated
    check_hist ${out_dir}/Histograms/${sampleName}.hist

    #   Begin calculating statistics per bp
    #   The minimum is the coverage on the first line of the "all" fields since they're already sorted
    local min=$(grep "all" "${out_dir}"/Histograms/${sampleName}.hist | head -n 1 | awk -F "\t" '{print $2}')
    #   The maximum is the coverage on the last line of the "all" fields
    local max=$(grep "all" "${out_dir}"/Histograms/${sampleName}.hist | tail -n 1 | awk -F "\t" '{print $2}')
    #   The mean is the sum of (each coverage * the percent of the genome at that coverage)
    local mean=$(grep "all" "${out_dir}"/Histograms/${sampleName}.hist | awk '{ sum += $2*$5 } END { print sum }')
    #   The mode is the coverage that has the highest percent of the genome at that coverge (excludes zero coverage)
    local mode=$(grep "all" "${out_dir}"/Histograms/${sampleName}.hist | tail -n +2 | sort -grk5,5 | head -1 | awk -F "\t" '{print $2}')
    #   The quantiles are a bit tricky...
    #   row_count will count how many rows down the "all" fields we are
    local row_count="0"
    #   freq_sum will be the sum of the frequency fields (column 5) from row 0 to row_count
    local freq_sum="0"
    #   While freq_sum < 0.25
    while [ $(echo "if ("${freq_sum}" < 0.25) 1 else 0" | bc) -eq 1 ]
    do
        ((row_count += 1))
        #   freq is the value of the frequency field (column 5) on the row corresponding to row_count
        local freq=$(grep "all" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $5}')
        #   Add freq to freq_sum until the while loop exits
        local freq_sum=$(echo "${freq_sum} + ${freq}" | bc -l)
    done
    #   The first quantile is the coverage on the row at which the cumulative frequency hits 0.25 or greater
    local Q1=$(grep "all" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $2}')
    #   Repeat for Q2 (median)
    while [ $(echo "if (${freq_sum} < 0.5) 1 else 0" | bc) -eq 1 ]
    do
        ((row_count += 1))
        local freq=$(grep "all" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $5}')
        local freq_sum=$(echo "${freq_sum} + ${freq}" | bc -l)
    done
    local Q2=$(grep "all" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $2}')
    #   Repeat for Q3
    while [ $(echo "if (${freq_sum} < 0.75) 1 else 0" | bc) -eq 1 ]
    do
        ((row_count += 1))
        local freq=$(grep "all" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $5}')
        local freq_sum=$(echo "${freq_sum} + ${freq}" | bc -l)
    done
    local Q3=$(grep "all" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $2}')
    #   Append the statistics to the summary file
    echo -e "${sampleName}"'\t'"${min}"'\t'"${Q1}"'\t'"${mode}"'\t'"${Q2}"'\t'"${mean}"'\t'"${Q3}"'\t'"${max}" >> "${out_dir}/${project}_coverage_summary_unfinished.tsv"
    #   Put a call to plotCoverage here
}

export -f EC_Coverage

#   This is to calculate histograms and summary statistics for whole genome data
function WG_Coverage() {
    local bam_file="$1"
    local bam_dir=$(dirname "${bam_file}")
    local out_dir="$2"
    local project="$3"
    #   Get the sample name without the .bam
    local sampleName=$(basename "${bam_file}" .bam)
    #   Generate coverage histograms as text files
    bedtools genomecov -ibam "${bam_file}" > ${out_dir}/Histograms/${sampleName}.hist
    #   Check if .hist file was successfully generated
    check_hist ${out_dir}/Histograms/${sampleName}.hist

    #   Begin calculating statistics per bp
    #   The minimum is the coverage on the first line of the "genome" fields since they're already sorted
    local min=$(grep "genome" "${out_dir}/Histograms/${sampleName}.hist" | head -n 1 | awk -F "\t" '{print $2}')
    #   The maximum is the coverage on the last line of the "all" fields
    local max=$(grep "genome" "${out_dir}/Histograms/${sampleName}.hist" | tail -n 1 | awk -F "\t" '{print $2}')
    #   The mean is the sum of (each coverage * the percent of the genome at that coverage)
    local mean=$(grep "genome" "${out_dir}/Histograms/${sampleName}.hist" | awk '{ sum += $2*$5 } END { print sum }')
    #   The mode is the coverage that has the highest percent of the genome at that coverge (excludes zero coverage)
    local mode=$(grep "genome" "${out_dir}/Histograms/${sampleName}.hist" | tail -n +2 | sort -grk5,5 | head -1 | awk -F "\t" '{print $2}')
    #   The quantiles are a bit tricky...
    #   row_count will count how many rows down the "all" fields we are
    local row_count="0"
    #   freq_sum will be the sum of the frequency fields (column 5) from row 0 to row_count
    local freq_sum="0"
    #   While freq_sum < 0.25
    while [ $(echo "if (${freq_sum} < 0.25) 1 else 0" | bc) -eq 1 ]
    do
        ((row_count += 1))
        #   freq is the value of the frequency field (column 5) on the row corresponding to row_count
        local freq=$(grep "genome" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $5}')
        #   Add freq to freq_sum until the while loop exits
        local freq_sum=$(echo "${freq_sum} + ${freq}" | bc -l)
    done
    #   The first quantile is the coverage on the row at which the cumulative frequency hits 0.25 or greater
    local Q1=$(grep "genome" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $2}')
    #   Repeat for Q2 (median)
    while [ $(echo "if (${freq_sum} < 0.5) 1 else 0" | bc) -eq 1 ]
    do
        ((row_count += 1))
        local freq=$(grep "genome" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $5}')
        local freq_sum=$(echo "${freq_sum} + ${freq}" | bc -l)
    done
    local Q2=$(grep "genome" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $2}')
    #   Repeat for Q3
    while [ $(echo "if (${freq_sum} < 0.75) 1 else 0" | bc) -eq 1 ]
    do
        ((row_count += 1))
        local freq=$(grep "genome" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $5}')
        local freq_sum=$(echo "${freq_sum} + ${freq}" | bc -l)
    done
    local Q3=$(grep "genome" "${out_dir}/Histograms/${sampleName}.hist" | head -n ${row_count} | tail -1 | awk -F "\t" '{print $2}')
    #   Append the statistics to the summary file
    echo -e "${sampleName}"'\t'"${min}"'\t'"${Q1}"'\t'"${mode}"'\t'"${Q2}"'\t'"${mean}"'\t'"${Q3}"'\t'"${max}" >> "${out_dir}/${project}_coverage_summary_unfinished.tsv"
    #   Put a call to plotCoverage here
}

export -f WG_Coverage

#   The main function that sets up and calls the various others
function Coverage_Mapping() {
    local sampleList="$1" # What is our list of samples?
    local outDirectory="$2"/Coverage_Mapping # Where do we store our results?
    local proj="$3" # What is the name of the project?
    local olderBedtools="$4"
    local regions="$5" # What is our regions file?
    # Make our output directories
    mkdir -p "${outDirectory}" \
        "${outDirectory}/Histograms" \
        "${outDirectory}/Plots"

    set -x # for debugging, delete later
    if ! [[ -f "${regions}" ]]
    then # Whole-genome sequencing
        echo "Running Coverage Mapping whole-genome mode..."
	    #   Naoki reordered the arguments, so empty $regions (i.e. WG) doesn't cause a problem. - Thanks.
        #   Make the header for the summary file
        echo -e "Sample name\tMin\t1st Q\tMode\tMedian\tMean\t3rd Q\tMax" >> "${outDirectory}/${proj}_coverage_summary_unfinished.tsv"
        parallel WG_Coverage {} "${outDirectory}" "${proj}" :::: "${sampleList}"
    else # Exome capture
        echo "Running Coverage Mapping using regions file..."
        #   Make the header for the summary file
        echo -e "Sample name\tMin\t1st Q\tMode\tMedian\tMean\t3rd Q\tMax" >> "${outDirectory}/${proj}_coverage_summary_unfinished.tsv"
        parallel EC_Coverage {} "${regions}" "${outDirectory}" "${proj}" "${olderBedtools}" :::: "${sampleList}"
    fi
    #   Make the header for the sorted summary file
    echo -e "Sample name\tMin\t1st Q\tMode\tMedian\tMean\t3rd Q\tMax" >> "${outDirectory}/${proj}_coverage_summary.tsv"
    #   Sort the summary file based on sample name
    tail -n +2 "${outDirectory}/${proj}_coverage_summary_unfinished.tsv" | sort >> "${outDirectory}/${proj}_coverage_summary.tsv"
    #   Remove the unsorted file
    rm "${outDirectory}/${proj}_coverage_summary_unfinished.tsv"
}

export -f Coverage_Mapping

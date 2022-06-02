#!/bin/bash

#   This script creates a high-confidence
#   subset of variants to use in variant recalibration.

set -e
set -o pipefail

#   What are the dependencies for Create_HC_Subset?
declare -a Create_HC_Subset_Dependencies=(parallel vcftools R vcfintersect python3 bcftools bedtools)

function Create_HC_Subset_GATK4() {
    local raw_vcf_file="$1"
    local vcf_list="$2" # What is our sample list?
    local out="$3" # Where are we storing our results?
    local barley="$4" # Is this barley?
    local project="$5" # What is the name of this project?
    local seqhand="$6" # Where is sequence_handling located?
    local qual_cutoff="$7" # What is the quality cutoff?
    local gq_cutoff="$8" # What is the genotyping quality cutoff?
    local max_lowgq="$9" # What is the maximum proportion of lowGQ samples?
    local dp_per_sample_cutoff="${10}" # What is the DP per sample cutoff?
    local max_het="${11}" # What is the maximum proportion of heterozygous samples?
    local max_miss="${12}" # What is the maximum proportion of missing samples?
    local memory="${13}" # How much memory can java use?
    local ref_gen="${14}" # Reference genome
    local gen_num="${15}" # Number of genomic regions to sample from
    local gen_len="${16}" # Length of genomic regions to sample from
    # Check if out dirs exist, if not make them
    mkdir -p ${out}/Create_HC_Subset \
             ${out}/Create_HC_Subset/Intermediates \
             ${out}/Create_HC_Subset/Percentile_Tables
    # Note: gzipping large files takes a long time and bcftools concat (based on a quick time comparison) runs faster with uncompressed vcf files. So, we will not gzip the VCF file.
    # 1. Determine if we need to concatenate all the split VCF files into a raw VCF file
    # Many users will want to back this file up since it is the most raw form of the SNP calls
    # Check if files are already concatenated, if so skip this time consuming step
    if [[ ${vcf_list} == "NA" ]]; then
        echo "Using raw variants VCF file provided: ${raw_vcf_file}"
        raw_vcf=${raw_vcf_file}
    else
        echo "Need to concatenate split vcf files."
        # Check if we have already concatenated the split vcf files (i.e., from a previous run of Create_HC_Subset)
        if [ -f ${out}/Create_HC_Subset/${project}_raw_variants.vcf.gz ]; then
            echo "Split vcf files have been concatenated, proceed with existing concatenated raw variants file: ${out}/Create_HC_Subset/${project}_raw_variants.vcf.gz"
            raw_vcf="${out}/Create_HC_Subset/${project}_raw_variants.vcf.gz"
        else
            echo "File doesn't exist, concatenating and sorting split VCF files..."
            out_subdir="${out}/Create_HC_Subset/Intermediates"
            cat ${vcf_list} > ${out_subdir}/temp-FileList.list # note suffix has to be .list
            # Check if we have specified a TMP directory (Note: pulled from global variable specified in config)
            if [ -z "${TMP}" ]; then
                echo "No temp directory specified. Proceeding without using temp directory."
                # This works for GATK 4, but not sure about GATK 3
                gatk --java-options "-Xmx${memory}" SortVcf \
                     -I ${out_subdir}/temp-FileList.list \
                     -O ${out}/Create_HC_Subset/${project}_raw_variants.vcf.gz
            else
                echo "Proceed using temp directory: ${TMP}"
                # This works for GATK 4, but not sure about GATK 3
                gatk --java-options "-Xmx${memory}" SortVcf \
                     --TMP_DIR ${TMP} \
                     -I ${out_subdir}/temp-FileList.list \
                     -O ${out}/Create_HC_Subset/${project}_raw_variants.vcf.gz
            fi
            rm -f ${out_subdir}/temp-FileList.list # Cleanup temp file
            raw_vcf="${out}/Create_HC_Subset/${project}_raw_variants.vcf.gz"
            echo "Finished concatenating and sorting split VCF files. Concatenated file is located at: ${raw_vcf}"
        fi
    fi

    # 2. Filter out indels using vcftools (DOES NOT apply to GATK 4 Create_HC_Subset handler, but this step is mentioned in the wiki so it is commented here so the step numbers match up)

    # 3. Create a percentile table for the unfiltered SNPs
    source "${seqhand}/HelperScripts/percentiles.sh"
    # Check if we have already created the percentiles table for the unfiltered SNPs
    # The *_unfiltered_DP_per_sample.txt should be the last file that gets created
    if [ -f ${out}/Create_HC_Subset/Percentile_Tables/${project}_unfiltered_DP_per_sample.txt ]
    then
        echo "Already generated percentiles table for unfiltered SNPs, proceed to next step."
    else
        echo "Generating percentiles table for unfiltered SNPs..."
        percentiles "${raw_vcf}" "${out}/Create_HC_Subset" "${project}" "unfiltered" "${seqhand}"
        echo "Finished generating percentiles table for unfiltered SNPs."
    fi
    if [[ "$?" -ne 0 ]]; then
        echo "Error creating raw percentile tables, exiting..." >&2
        exit 32 # If something went wrong with the R script, exit
    fi

    # 4. Filter out sites that are low quality
    # We don't want to re-run this time consuming step if all of our cutoffs are the same as the previous run
    #   (in the case that we are re-running this handler due to exceeding walltime, etc.).
    # We only want to run this step if we have new cutoffs provided
    # If file exists, check header line for current VCF file's cutoffs used
    if [ -f ${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf ]
    then
        echo "Filtered vcf file exists, checking if file is empty..."
        if [ -s ${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf ]; then
            echo "Existing filtered vcf file is NOT empty."
            # Check if cutoffs have been changed
            echo "Checking if cutoffs have been changed..."
            # First check if we have a header line that starts with ##Create_HC_Subset_filter_cutoffs
            # This is used to check if our current cutoffs have been updated
            set -x # for debugging
            if grep -q "##Create_HC_Subset_filter_cutoffs" ${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf
            then
                # Expected header exists, check if cutoffs have been updated
                cutoffs_in_config=($(echo "Quality:"${qual_cutoff} "Max_het:"${max_het} "Max_miss:"${max_miss} "Genotype_Quality:"${gq_cutoff} "Max_low_gq:"${max_lowgq} "DP_per_sample:"${dp_per_sample_cutoff} | tr ' ' '\n'))
                cutoffs_in_vcf=($(grep "##Create_HC_Subset_filter_cutoffs" ${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf | cut -d'=' -f 2 | tr ',' '\n'))
            else
                # Expected header doesn't exist
                echo "VCF header line starting with ##Create_HC_Subset_filter_cutoffs doesn't exist."
                echo "If you have updated your cutoffs, the easiest solution is to delete your filtered VCF file (${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf) and re-run this handler."
                echo "If you know you have NOT updated your cutoffs, please read the following:"
                echo "Please check your VCF and make sure it has the header line starting with ##Create_HC_Subset_filter_cutoffs containing your previous run's cutoff values. If not, please add it."
                echo "Here is the format using the current cutoffs specified in your config:"
                echo "##Create_HC_Subset_filter_cutoffs=""Quality:"${qual_cutoff}",Het:"${max_het}",Max_miss:"${max_miss}",Genotype_Quality:"${gq_cutoff}",Max_low_gq:"${max_lowgq}",DP_per_sample:"${dp_per_sample_cutoff}
                exit 22 # Exit
            fi
            # Identify differences in config vs filtered vcf cutoffs
            cutoff_diffs=$(diff <(printf "%s\n" "${cutoffs_in_config[@]}") <(printf "%s\n" "${cutoffs_in_vcf[@]}"))
            if [[ -z "${cutoff_diffs}" ]]; then
                echo "Cutoffs are identical, none of them have been updated."
                echo ${cutoffs_in_vcf[@]} "Cutoff in VCF"
                echo ${cutoffs_in_config[@]} "Cutoff in Config"
            else
                echo "We have one or more updated cutoffs, re-run filtering with new cutoffs."
                echo "Cutoff in VCF" ${cutoffs_in_vcf[@]}
                echo "Updated cutoff in Config" ${cutoffs_in_config[@]}
                # Cutoffs have been changed, re-run filtering with updated cutoffs
                echo "Filtering on quality and depth."
                bcftools filter -e "INFO/DP < ${dp_per_sample_cutoff} || QUAL < ${qual_cutoff}" ${raw_vcf} > "${out}/Create_HC_Subset/Intermediates/${project}_filtered_dp_and_qual.vcf"

                echo "Filtering on proportion heterozygous and proportion missing"
                python3 ${seqhand}/HelperScripts/Site_GQ_Het_Missing_Filter.py \
                    "${out}/Create_HC_Subset/Intermediates/${project}_filtered_dp_and_qual.vcf" \
                    "${max_het}" \
                    "${max_miss}" \
                    "${qual_cutoff}" \
                    "${gq_cutoff}" \
                    "${max_lowgq}" \
                    "${dp_per_sample_cutoff}" > "${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf"
                if [[ "$?" -ne 0 ]]; then
                    echo "Error with Site_GQ_Het_Missing_Filter.py, exiting..." >&2
                    exit 22 # If something went wrong with the python script, exit
                fi
                echo "Finished filtering on quality/depth and proportion hterozygous/missing."
                # To save space, cleanup temp file
                rm ${out}/Create_HC_Subset/Intermediates/${project}_filtered_dp_and_qual.vcf*
                # Remove filtered matrices (if they exist) used to calculate percentiles. Since we updated our cutoffs,
                #   we will re-calculate the filtered percentiles tables
                filtered_matrices_arr=("${out}/Create_HC_Subset/Intermediates/${project}_filtered.GQ.FORMAT" "${out}/Create_HC_Subset/Intermediates/${project}_filtered.GQ.matrix" "${out}/Create_HC_Subset/Intermediates/${project}_filtered.gdepth" "${out}/Create_HC_Subset/Intermediates/${project}_filtered.gdepth.matrix" "${out}/Create_HC_Subset/Intermediates/temp_flattened_${project}_filtered.GQ.matrix.txt" "${out}/Create_HC_Subset/Intermediates/temp_flattened_${project}_filtered.gdepth.matrix.txt")
                for m in ${filtered_matrices_arr[@]}
                do
                    if [ -f ${m} ]; then
                        echo "Filtered matrix already exists, remove before re-doing filtering: ${m}"
                        rm ${m}
                    fi
                done
            fi
        else
            echo "Filtered vcf file exists but is empty."
            echo "Check if *_filtered_dp_and_qual.vcf (filtered on quality and depth) file exists."
            if [ -f ${out}/Create_HC_Subset/Intermediates/${project}_filtered_dp_and_qual.vcf ]; then
                echo "File exists: ${out}/Create_HC_Subset/Intermediates/${project}_filtered_dp_and_qual.vcf"
                echo "Assuming *_filtered_dp_and_qual.vcf file was successfully generated and proceed to filtering on proportion heterozygous and proportion missing. If this is not the case, please delete the *_filtered_dp_and_qual.vcf file and re-run this handler."
                echo "Removing empty vcf file and re-generate vcf file filtered on proportion heterozygous and proportion missing."
                rm ${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf
                echo "Filtering on proportion heterozygous and proportion missing"
                python3 ${seqhand}/HelperScripts/Site_GQ_Het_Missing_Filter.py \
                    "${out}/Create_HC_Subset/Intermediates/${project}_filtered_dp_and_qual.vcf" \
                    "${max_het}" \
                    "${max_miss}" \
                    "${qual_cutoff}" \
                    "${gq_cutoff}" \
                    "${max_lowgq}" \
                    "${dp_per_sample_cutoff}" > "${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf"
                if [[ "$?" -ne 0 ]]; then
                    echo "Error with Site_GQ_Het_Missing_Filter.py, exiting..." >&2
                    exit 22 # If something went wrong with the python script, exit
                fi
                echo "Finished filtering on quality/depth and proportion hterozygous/missing."
                # To save space, cleanup temp file
                rm ${out}/Create_HC_Subset/Intermediates/${project}_filtered_dp_and_qual.vcf*
                # Remove filtered matrices (if they exist) used to calculate percentiles. Since we updated our cutoffs,
                #   we will re-calculate the filtered percentiles tables
                filtered_matrices_arr=("${out}/Create_HC_Subset/Intermediates/${project}_filtered.GQ.FORMAT" "${out}/Create_HC_Subset/Intermediates/${project}_filtered.GQ.matrix" "${out}/Create_HC_Subset/Intermediates/${project}_filtered.gdepth" "${out}/Create_HC_Subset/Intermediates/${project}_filtered.gdepth.matrix" "${out}/Create_HC_Subset/Intermediates/temp_flattened_${project}_filtered.GQ.matrix.txt" "${out}/Create_HC_Subset/Intermediates/temp_flattened_${project}_filtered.gdepth.matrix.txt")
                for m in ${filtered_matrices_arr[@]}
                do
                    if [ -f ${m} ]; then
                        echo "Filtered matrix already exists, remove before re-doing filtering: ${m}"
                        rm ${m}
                    fi
                done
            fi
        fi
    else
        # This is our first time filtering the vcf file
        echo "Filtering on quality and depth."
        bcftools filter -e "INFO/DP < ${dp_per_sample_cutoff} || QUAL < ${qual_cutoff}" ${raw_vcf} > "${out}/Create_HC_Subset/Intermediates/${project}_filtered_dp_and_qual.vcf"

        echo "Filtering on proportion heterozygous and proportion missing"
        python3 ${seqhand}/HelperScripts/Site_GQ_Het_Missing_Filter.py \
                "${out}/Create_HC_Subset/Intermediates/${project}_filtered_dp_and_qual.vcf" \
                "${max_het}" \
                "${max_miss}" \
                "${qual_cutoff}" \
                "${gq_cutoff}" \
                "${max_lowgq}" \
                "${dp_per_sample_cutoff}" > "${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf"
        if [[ "$?" -ne 0 ]]; then
            echo "Error with Site_GQ_Het_Missing_Filter.py, exiting..." >&2
            exit 22 # If something went wrong with the python script, exit
        fi
        echo "Finished filtering on quality/depth and proportion hterozygous/missing."
        # To save space, cleanup temp file
        rm ${out}/Create_HC_Subset/Intermediates/${project}_filtered_dp_and_qual.vcf*
    fi

    # Get the number of sites left after filtering
    local num_sites=$(grep -v "#" "${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf" | wc -l)
    if [[ "${num_sites}" == 0 ]]; then
        echo "No sites left after filtering! Try using less stringent criteria. Exiting..." >&2
        exit 23 # If no sites left, error out with message
    fi

    # 5. Create a percentile table for the filtered SNPs
    echo "Generating percentiles table for filtered SNPs..."
    percentiles "${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf" "${out}/Create_HC_Subset" "${project}" "filtered" "${seqhand}"
    echo "Finished generating percentiles table for filtered SNPs."
    if [[ "$?" -ne 0 ]]; then
        echo "Error creating filtered percentile tables, exiting..." >&2
        exit 33 # If something went wrong with the R script, exit
    fi

    # 6. Remove any sites that aren't polymorphic (minor allele count of 0). This is just a safety precaution
    local vcfoutput="${out}/Create_HC_Subset/Intermediates/${project}_filtered.vcf"
    echo "Removing sites that aren't polymorphic."
    vcftools --vcf "${vcfoutput}" --non-ref-ac 1 --recode --recode-INFO-all --out "${out}/Create_HC_Subset/${project}_high_confidence_subset"
    mv "${out}/Create_HC_Subset/${project}_high_confidence_subset.recode.vcf" "${out}/Create_HC_Subset/${project}_high_confidence_subset.vcf" # Rename the output file
    # Index vcf file
    gatk IndexFeatureFile -F ${out}/Create_HC_Subset/${project}_high_confidence_subset.vcf
    echo "Finished removing sites that aren't polymorphic."

    # 7. Remove intermediates to clear space
    # Since the user likely will run this handler multiple times, don't remove intermediate files
    # that don't need to be re-generated (i.e., filtered indels vcf) when handler is re-run.
    # Let the user decide what to remove when they are done.
    # rm -Rf "${out}/Intermediates" # Comment out this line if you need to debug this handler

    # 8. Generate graphs showing distributions of variant annotations
    # First, check if VCF is compressed. If so, decompress temporarily
    if [[ ${raw_vcf} == *".gz"* ]]; then
        # Decompress VCF
        echo "Decompressing VCF file temporarily for graphing annotations..."
        file_prefix=$(basename ${raw_vcf} .vcf.gz)
        bgzip -dc ${raw_vcf} > ${out}/Create_HC_Subset/${file_prefix}.vcf
        raw_vcf=${out}/Create_HC_Subset/${file_prefix}.vcf
    fi
    source "${seqhand}/HelperScripts/graph_annotations.sh"
    vcf_prefix=Raw # Raw VCF file
    hc_prefix=HC # High Confidence
    graph_annotations \
        "${raw_vcf}" \
        "${out}/Create_HC_Subset/${project}_high_confidence_subset.vcf" \
        "${out}/Create_HC_Subset" \
        "${project}" \
        "${ref_gen}" \
        "${seqhand}" \
        "${gen_num}" \
        "${gen_len}" \
        "${vcf_prefix}" \
        "${hc_prefix}" \
        "pair"
    # Cleanup intermediate file to save space
    rm ${out}/Create_HC_Subset/${file_prefix}.vcf
}

export -f Create_HC_Subset_GATK4

#   A function to call each filtering step
function Create_HC_Subset_GATK3() {
    local sample_list="$1" # What is our sample list?
    local out="$2"/Create_HC_Subset # Where are we storing our results?
    local bed="$3" # Where is the capture regions bed file?
    local barley="$4" # Is this barley?
    local project="$5" # What is the name of this project?
    local seqhand="$6" # Where is sequence_handling located?
    local qual_cutoff="$7" # What is the quality cutoff?
    local gq_cutoff="$8" # What is the genotyping quality cutoff?
    local dp_per_sample_cutoff="$9" # What is the DP per sample cutoff?
    local max_het="${10}" # What is the maximum number of heterozygous samples?
    local max_bad="${11}" # What is the maximum number of bad samples?
    local temp_dir="${12}" # Where can we store temporary files while running parallel?
    local ref_gen="${13}" # Reference genome
    local gen_num="${14}" # Number of genomic regions to sample from
    local gen_len="${15}" # Length of genomic regions to sample from
    #   Make sure the out directories exist
    mkdir -p "${out}/Intermediates/Parts"
    mkdir -p "${out}/Percentile_Tables"
    #   1. Gzip all the chromosome part VCF files
    source "${seqhand}/HelperScripts/gzip_parts.sh"
    # Note: gzipping large files takes a long time and bcftools concat (based on a quick time comparison) runs faster
    # with uncompressed vcf files. So, for large VCF files, you may not want to gzip the files.
    parallel -v gzip_parts {} "${out}/Intermediates/Parts" :::: "${sample_list}" # Do the gzipping in parallel, preserve original files
    "${seqhand}/HelperScripts/sample_list_generator.sh" .vcf.gz "${out}/Intermediates/Parts" gzipped_parts.list # Make a list of the gzipped files for the next step
    #   2. Use bcftools to concatenate all the gzipped VCF files
    bcftools concat -f "${out}/Intermediates/Parts/gzipped_parts.list" > "${out}/Intermediates/${project}_concat.vcf"
    #   3. If exome capture, filter out SNPs outside the exome capture region. If not, then do nothing (This is necessary for GATK v3 since we would have called SNPs in all regions, but not always necessary for GATK 4 if we provided GATK4 with regions)
    if ! [[ "${bed}" == "NA" ]]
    then
        vcfintersect -b "${bed}" "${out}/Intermediates/${project}_concat.vcf" > "${out}/Intermediates/${project}_capture_regions.vcf" # Perform the filtering
        local step3output="${out}/Intermediates/${project}_capture_regions.vcf"
    else
        local step3output="${out}/Intermediates/${project}_concat.vcf"
    fi
    #   4. Filter out indels using vcftools
    vcftools --vcf "${step3output}" --remove-indels --recode --recode-INFO-all --out "${out}/Intermediates/${project}_no_indels" # Perform the filtering
    #   5. Create a percentile table for the unfiltered SNPs
    source "${seqhand}/HelperScripts/percentiles.sh"
    percentiles "${out}/Intermediates/${project}_no_indels.recode.vcf" "${out}" "${project}" "unfiltered" "${seqhand}"
    if [[ "$?" -ne 0 ]]; then echo "Error creating raw percentile tables, exiting..." >&2; exit 32; fi # If something went wrong with the R script, exit
    #   6. Filter out sites that are low quality
    python3 "${seqhand}/HelperScripts/filter_sites.py" "${out}/Intermediates/${project}_no_indels.recode.vcf" "${qual_cutoff}" "${max_het}" "${max_bad}" "${gq_cutoff}" "${dp_per_sample_cutoff}" > "${out}/Intermediates/${project}_filtered.vcf"
    if [[ "$?" -ne 0 ]]; then echo "Error with filter_sites.py, exiting..." >&2; exit 22; fi # If something went wrong with the python script, exit
    local num_sites=$(grep -v "#" "${out}/Intermediates/${project}_filtered.vcf" | wc -l) # Get the number of sites left after filtering
    if [[ "${num_sites}" == 0 ]]; then echo "No sites left after filtering! Try using less stringent criteria. Exiting..." >&2; exit 23; fi # If no sites left, error out with message
    #   7. Create a percentile table for the filtered SNPs
    percentiles "${out}/Intermediates/${project}_filtered.vcf" "${out}" "${project}" "filtered" "${seqhand}"
    if [[ "$?" -ne 0 ]]; then echo "Error creating filtered percentile tables, exiting..." >&2; exit 33; fi # If something went wrong with the R script, exit
    #   8. If barley, convert the parts positions into pseudomolecular positions. If not, then do nothing
    if [[ "${barley}" == true ]]
    then
        python3 "${seqhand}/HelperScripts/convert_parts_to_pseudomolecules.py" "${out}/Intermediates/${project}_filtered.vcf" > "${out}/Intermediates/${project}_pseudo.vcf"
        local step8output="${out}/Intermediates/${project}_pseudo.vcf"
    else
        local step8output="${out}/Intermediates/${project}_concat.vcf"
    fi
    #   9. Remove any sites that aren't polymorphic (minor allele count of 0). This is just a safety precaution
    vcftools --vcf "${step8output}" --non-ref-ac 1 --recode --recode-INFO-all --out "${out}/${project}_high_confidence_subset"
    mv "${out}/${project}_high_confidence_subset.recode.vcf" "${out}/${project}_high_confidence_subset.vcf" # Rename the output file
    #   10. Remove intermediates to clear space
    # rm -Rf "${out}/Intermediates" # Comment out this line if you need to debug this handler
}

#   Export the function
export -f Create_HC_Subset_GATK3

#!/usr/bin/env nextflow

/*
================================================================================
                                  nf-core/sarek
================================================================================
--------------------------------------------------------------------------------
egenesisbio/rnaseq:
  report for xeno genes expression and splicing progile
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
*/

def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run egenesisbio/rnaseq/report.nf --input sample.tsv -profile docker

    Mandatory arguments:
        --input                     BAM files.

        -profile                    Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.


    References                      If not specified in the configuration file or you wish to overwrite any of the references.
        --fasta                     Xeno FASTA reference
        --xeno                      chromosome names for xeno sequences
        --gtf                       GTF file with xeno genes


    Other options:
        --outdir                    The output directory where the results will be saved
        --monochrome_logs           Logs will be without colors
        --email                     Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
        --maxMultiqcEmailFileSize   Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
        -name                       Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
        --awsqueue                  The AWSBatch JobQueue that needs to be set when running on AWSBatch
        --awsregion                 The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

forwardStranded = params.forwardStranded
reverseStranded = params.reverseStranded
unStranded = params.unStranded

Channel.from(params.xeno)
        .into{ ch_xeno; ch_xeno2cov }

Channel
    .fromPath(params.gtf, checkIfExists: true)
    .ifEmpty { exit 1, "GTF annotation file not found: ${params.gtf}" }
    .into { gtf_stringtieFPKM; gtf_makeHisatSplicesites; gtf_makeHISATindex; gtf_viz}

Channel.fromPath(params.fasta, checkIfExists: true)
    .ifEmpty { exit 1, "Genome fasta file not found: ${params.fasta}" }
    .into { ch_fasta_for_hisat_index; fasta; ch_fasta_stringtie }

if(params.readPaths){
        Channel
            .from(params.readPaths)
            .map { row -> [ row[0], [file(row[1][0])]] }
            .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
            .into { ch_bams }
} else {
    Channel
        .fromFilePairs( params.reads, size: 1 )
        .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!." }
        .map { row -> [ row[1][0].baseName - ~/(.R1)?(_R1)?(_trimmed)?(_val_1)??(Aligned.sortedByCoord.out.markDups)?(.bam)?$/, [row[1][0]] ] }
        .into { ch_bams }
}

custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}
/*
================================================================================
                                PRINTING SUMMARY
================================================================================
*/

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision)          summary['Pipeline Release']    = workflow.revision
summary['Run Name']          = custom_runName ?: workflow.runName
summary['Max Resources']     = "${params.max_memory} memory, ${params.max_cpus} cpus, ${params.max_time} time per job"
if (workflow.containerEngine)   summary['Container']         = "${workflow.containerEngine} - ${workflow.container}"
if (params.fasta)               summary['FASTA']             = params.fasta
if (params.gtf)                 summary['GTF']        = params.gtf
if (params.xeno)                summary['XENO']        = params.xeno

summary['Output dir']        = params.outdir
summary['Launch dir']        = workflow.launchDir
summary['Working dir']       = workflow.workDir
summary['Script dir']        = workflow.projectDir
summary['User']              = workflow.userName

if (params.fasta)                 summary['fasta']                 = params.fasta


if (workflow.profile == 'awsbatch') {
    summary['AWS Region']        = params.awsregion
    summary['AWS Queue']         = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description)  summary['Config Description']  = params.config_profile_description
if (params.config_profile_contact)      summary['Config Contact']      = params.config_profile_contact
if (params.config_profile_url)          summary['Config URL']          = params.config_profile_url
if (params.email) {
    summary['E-mail Address']        = params.email
    summary['MultiQC maxsize']       = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k, v -> "${k.padRight(18)}: $v" }.join("\n")
if (params.monochrome_logs) log.info "----------------------------------------------------"
else log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()


/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help message
if (params.help) exit 0, helpMessage()


process bamSplice {
    label 'cpus_2'
    label 'BamTools'

    tag {sample}
    
    publishDir "${params.outdir}/${sample}", mode: 'copy'

    input:
        set sample, file(bam) from ch_bams

    output:
        set val(sample), file("*fq.gz") into ch_reads

    script:
    """
    samtools index ${bam}
    samtools view -hb ${bam} ${params.xeno} | samtools fastq -1 ${sample}_${params.xeno}_1.fq.gz -2 ${sample}_${params.xeno}_2.fq.gz -0 /dev/null -s /dev/null -n -F 0x900  /dev/stdin 
    """

}

process makeHisatSplicesites_small {
    tag "$gtf"
    publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                saveAs: { params.saveReference ? it : null }, mode: 'copy'

    input:
    file gtf from gtf_makeHisatSplicesites

    output:
    file "${gtf.baseName}.hisat2_splice_sites.txt" into indexing_splicesites, alignment_splicesites

    script:
    """
    hisat2_extract_splice_sites.py $gtf > ${gtf.baseName}.hisat2_splice_sites.txt
    """
}

process makeHISATindex_small {
    label 'low_memory'
    tag "$fasta"
    publishDir path: { params.saveReference ? "${params.outdir}/reference_genome" : params.outdir },
                saveAs: { params.saveReference ? it : null }, mode: 'copy'

    input:
    file fasta from ch_fasta_for_hisat_index
    file indexing_splicesites from indexing_splicesites
    file gtf from gtf_makeHISATindex

    output:
    file "${fasta.baseName}.*.ht2*" into hs2_indices

    script:
    extract_exons = "hisat2_extract_exons.py $gtf > ${gtf.baseName}.hisat2_exons.txt"
    ss = "--ss $indexing_splicesites"
    exon = "--exon ${gtf.baseName}.hisat2_exons.txt"

    """
    # $extract_exons
    hisat2-build -p ${task.cpus} $fasta ${fasta.baseName}.hisat2_index
    """
}

process hisat2Align_small {
    label 'low_memory'
    publishDir "${params.outdir}/HISAT2", mode: 'copy',
        saveAs: {filename ->
            if (filename.indexOf(".hisat2_summary.txt") > 0) "logs/$filename"
            else null
        }

    input:
    set sample, file(reads) from ch_reads
    file hs2_indices from hs2_indices.collect()
    file alignment_splicesites from alignment_splicesites.collect()

    output:
    file "${prefix}.bam" into hisat2_bam
    file "${prefix}.hisat2_summary.txt" into alignment_logs
    file "unmapped.hisat2*" optional true

    script:
    index_base = hs2_indices[0].toString() - ~/.\d.ht2l?/
    prefix = reads[0].toString() - ~/(_R1)?(_trimmed)?(_val_1)?(\.fq)?(\.fastq)?(\.gz)?$/
    def rnastrandness = ''
    if (forwardStranded && !unStranded){
        rnastrandness = '--rna-strandness FR'
    } else if (reverseStranded && !unStranded){
        rnastrandness = params.singleEnd ? '--rna-strandness R' : '--rna-strandness RF'
    }
    

    unaligned = "--un-conc-gz unmapped.hisat2.gz" 
    """
    hisat2 -x $index_base \\
            -1 ${reads[0]} \\
            -2 ${reads[1]} \\
            $rnastrandness \\
            --known-splicesite-infile $alignment_splicesites \\
            --no-mixed \\
            --no-discordant \\
            -p ${task.cpus} $unaligned\\
            --met-stderr \\
            --new-summary \\
            --dta \\
            --summary-file ${prefix}.hisat2_summary.txt \\
            | samtools view -bS -F 4 -F 8 -F 256 - > ${prefix}.bam
    """
}

process hisat2_sortOutput {
    label 'low_memory'
    tag "${hisat2_bam.baseName}"
    publishDir "${params.outdir}/HISAT2", mode: 'copy'

    input:
    file hisat2_bam

    output:
    file "${hisat2_bam.baseName}.sorted.bam" into bam_stringtieFPKM, bam_mosdepth
    file "${hisat2_bam.baseName}.sorted.bam.bai" into bam_index, bai_mosdepth

    script:
    """
    samtools sort \\
        $hisat2_bam \\
        -@ ${task.cpus} \\
        -o ${hisat2_bam.baseName}.sorted.bam
    samtools index ${hisat2_bam.baseName}.sorted.bam
    """
}

/*
* STEP N - stringtie FPKM
*/
process stringtieFPKM_small {
    label 'low_memory'
    publishDir "${params.outdir}/stringtieFPKM", mode: 'copy',
        saveAs: {filename ->
            if (filename.indexOf("transcripts.gtf") > 0) "transcripts/$filename"
            else if (filename.indexOf("cov_refs.gtf") > 0) "cov_refs/$filename"
            else if (filename.indexOf("transcripts.fa") > 0) "fasta/$filename"
            else "$filename"
        }


    input:
    file fasta from ch_fasta_stringtie
    file(bam) from bam_stringtieFPKM
    file gtf from gtf_stringtieFPKM.collect()

    output:
    file "*_transcripts.gtf"  into stringtieGTF  
    file "*_merged_transcripts.gtf"
    file "*.gene_abund.txt"
    file "*.cov_refs.gtf"
    file "*.fa"

    script:
    def st_direction = ''
    if (forwardStranded && !unStranded){
        st_direction = "--fr"
    } else if (reverseStranded && !unStranded){
        st_direction = "--rf"
    }
    name = bam.toString() - ~/(_R1)?(_trimmed)?(\.sorted\.bam)?(\.fq)?(\.fastq)?(\.gz)?$/

    """
    stringtie $bam \\
        $st_direction \\
        -o ${name}_transcripts.gtf \\
        -v \\
        -G $gtf \\
        -A ${name}.gene_abund.txt \\
        -C ${name}.cov_refs.gtf
    stringtie ${name}_transcripts.gtf --merge -G $gtf -o ${name}_merged_transcripts.gtf
    gffread -F -w ${name}_transcripts.fa -g $fasta ${name}_transcripts.gtf
    """
}


process viz {
    label 'low_memory'
    tag "${bam.baseName}"
    publishDir "${params.outdir}/viz/${bam.baseName}", mode: 'copy'

    input:
    file bam from bam_mosdepth 
    file bai from bai_mosdepth
    file gtf from stringtieGTF
    file ref_gtf from gtf_viz

    output:
    file "*mosdepth*"
    file "*gz"
    file "*tsv"
    file "*pdf"

    script:
    """
    mosdepth -b 1 ${bam.baseName} ${bam}
    gffread ${gtf} --table @chr,@start,@end,@strand,@exons,reference_id,ref_gene_id,ref_gene_name,TPM  --keep-genes -o ${bam.baseName}_transcripts.tsv
    gffread ${ref_gtf} --table @chr,@start,@end,@strand,@exons,gene_name -o ${bam.baseName}_ref_transcripts.tsv
    
    plot_xeno.R ${bam.baseName}.per-base.bed.gz  ${bam.baseName}_ref_transcripts.tsv ${bam.baseName}_transcripts.tsv ${bam.baseName}_${params.xeno}.pdf
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[egenesisbio/report] Successful: ${workflow.runName}"
    if (!workflow.success) subject = "[egenesisbio/report] FAILED: ${workflow.runName}"
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if (workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[egenesisbio/report] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[egenesisbio/report] Could not attach MultiQC report to summary email"
    }

    // Render the TXT template
    // def engine = new groovy.text.GStringTemplateEngine()
    // def tf = new File("$baseDir/assets/email_template.txt")
    // def txt_template = engine.createTemplate(tf).make(email_fields)
    // def email_txt = txt_template.toString()

    // Render the HTML template
    // def hf = new File("$baseDir/assets/email_template.html")
    // def html_template = engine.createTemplate(hf).make(email_fields)
    // def email_html = html_template.toString()

    // Render the sendmail template
    // def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    // def sf = new File("$baseDir/assets/sendmail_template.txt")
    // def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    // def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    // if (params.email) {
    //     try {
    //         if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
    //         // Try to send HTML e-mail using sendmail
    //         [ 'sendmail', '-t' ].execute() << sendmail_html
    //         log.info "[egenesisbio/report] Sent summary e-mail to $params.email (sendmail)"
    //     } catch (all) {
    //         // Catch failures and try with plaintext
    //         [ 'mail', '-s', subject, params.email ].execute() << email_txt
    //         log.info "[egenesisbio/report] Sent summary e-mail to $params.email (mail)"
    //     }
    // }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) output_d.mkdirs()
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_reset  = params.monochrome_logs ? '' : "\033[0m";
    c_red    = params.monochrome_logs ? '' : "\033[0;31m";
    c_green  = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "${c_purple}Warning, pipeline completed, but with errored process(es)${c_reset}"
        log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCountFmt}${c_reset}"
        log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCountFmt}${c_reset}"
    }

    if (workflow.success) log.info "${c_purple}[egenesisbio/report]${c_green} Pipeline completed successfully${c_reset}"
    else {
        checkHostname()
        log.info "${c_purple}[egenesisbio/report]${c_red} Pipeline completed with errors${c_reset}"
    }
}

/*
================================================================================
                                nf-core functions
================================================================================
*/

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'egenesisbio-report-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'egenesisbio/report Workflow Summary'
    section_href: 'https://github.com/egenesisbio/report'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k, v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

def nfcoreHeader() {
    // Log colors ANSI codes
    c_reset  = params.monochrome_logs ? '' : "\033[0m";
    c_dim    = params.monochrome_logs ? '' : "\033[2m";
    c_black  = params.monochrome_logs ? '' : "\033[0;30m";
    c_red    = params.monochrome_logs ? '' : "\033[0;31m";
    c_green  = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue   = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan   = params.monochrome_logs ? '' : "\033[0;36m";
    c_white  = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
        ${c_white}____${c_reset}
    ${c_purple}  egenesisbio/report v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}

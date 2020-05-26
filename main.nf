
params.outdir = "output"

def checkpoints_to_reference = [
    "tinylstm": "docker://cpllab/language-models:tinylstm",
]

checkpoints = Channel.fromPath("checkpoints/*/*", type: "dir").map { f ->
    // yields (path, (model, corpus, seed)) tuples
    def match = (f.toString() =~ /checkpoints\/(.+)\/(.+)_(.+)$/)[0]
    tuple(f, match[1], match[2], match[3])
}


suites = Channel.fromPath("test_suites/json/*.json")


process computeSuiteSurprisals {
    publishDir "${params.outdir}/json"

    input:
    set file(checkpoint_dir), val(model_name), val(corpus), val(seed), \
        file(test_suite) \
        from checkpoints.combine(suites)

    output:
    set model_name, corpus, seed, suite_name, file("${tag_name}.json") \
        into run_results

    tag "${tag_name}"

    script:
    model_ref = checkpoints_to_reference[model_name]
    checkpoint_ref = "${model_name}_${corpus}_${seed}"
    suite_name = "${test_suite.simpleName}"
    tag_name = "${suite_name}_${checkpoint_ref}"

    """
    /usr/bin/env bash
    source /home/jon/.local/share/virtualenvs/cli-dcBL6M9Q/bin/activate
    export PYTHONPATH=/home/jon/Projects/syntaxgym/cli:/home/jon/Projects/lm-zoo
    export PATH="/home/jon/Projects/syntaxgym/cli/bin:\$PATH"
    syntaxgym -v compute-surprisals \
        ${model_ref} ${test_suite} \
        --checkpoint ${checkpoint_dir} \
        > ${tag_name}.json
    """
}


process evaluateSuite {
    publishDir "${params.outdir}/csv"

    input:
    set val(model_name), val(corpus), val(seed), val(test_suite), file(results_json) \
        from run_results

    output:
    set model_name, corpus, seed, test_suite, file("${tag_name}.csv") \
        into csv_results

    tag "${tag_name}"
    script:
    tag_name = results_json.simpleName

    """
    /usr/bin/env bash
    source /home/jon/.local/share/virtualenvs/cli-dcBL6M9Q/bin/activate
    export PYTHONPATH=/home/jon/Projects/syntaxgym/cli:/home/jon/Projects/lm-zoo
    export PATH="/home/jon/Projects/syntaxgym/cli/bin:\$PATH"
    syntaxgym -v evaluate ${results_json} \
        > ${tag_name}.csv
    """
}


// Drop metadata
csv_results.map { it[4] }.into { csv_results_simple }


process concatenateResults {
    publishDir "${params.outdir}"

    input:
    file(csv_files) from csv_results_simple.collect()

    output:
    file("all_results.tsv")

    """
    #!/usr/bin/env python
    from pathlib import Path
    import re

    import pandas as pd

    all_dfs = []
    for path in Path(".").glob("*.csv"):
        match = re.match(r"([-\\w_]+)_(\\w+)_([-\\w]+)_(\\d+).csv", path.name)
        test_suite, model_name, corpus, seed = match.groups()

        df = pd.read_csv(path, delim_whitespace=True)
        df["model_name"] = model_name
        df["corpus"] = corpus
        df["seed"] = seed
        all_dfs.append(df)

    all_dfs = pd.concat(all_dfs).set_index(["model_name", "corpus", "seed",
                                            "suite", "item_number",
                                            "prediction_id"])
    all_dfs.to_csv("all_results.tsv", sep="\\t")
    """
}
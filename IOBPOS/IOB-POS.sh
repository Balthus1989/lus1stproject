#!/bin/bash

source clean.sh
echo -n "Enter the ngram-order > "
read order
echo -n "Enter smoothing (absolute, katz, kneser_ney, unsmoothed, witten_bell) > "
read smooth

#creation of the lexicon file, with # as sentence separator
echo "Lexicon generation..."
cat NLSPARQL.train.feats.txt | awk '{print $1}' | sed 's/^ *$/#/g' | tr '\n' ' ' > train.dict
#creation of a file, containing the sentences
tr '#' '\n' < train.dict | sed 's/^ *//g' > train.phrases
#lexicon generation through n-gramsymbols
ngramsymbols < train.phrases > train.symb
echo "Done! Lexicon created!"

echo "Token - IOB - POS Tag file generation..."
#IOB tag (C(IOB(i))) count
paste NLSPARQL.train.data NLSPARQL.train.feats.txt | awk '{print $1, $2, $4}' > NLSPARQL.iob-pos
sed 's/\//-/g' NLSPARQL.iob-pos | awk 'NF==0 {print " "} NF==3 {print $1, $2"-"$3}' > iob-pos.temp
mv iob-pos.temp NLSPARQL.iob-pos
cat NLSPARQL.iob-pos | awk '{print $2, $3}' | sed '/^ *$/d' | sort | uniq -c | awk '{OFS="\t"; print $2, $1}' > train.IOB-POS.counts
#Token-tag ( C(IOB(i), w(i))) count
cat NLSPARQL.iob-pos | sed '/^ *$/d' | sort | uniq -c | sed 's/^ *//g' | awk '{OFS="\t"; print $2, $3, $1}' > train.TOK-IOB-POS.counts

#P(w(i)|t(i)) = C(t(i), w(i))/C(t(i)) computation
while read -r line
do 
   tokenpos=$(echo $line | awk '{OFS="\t"; print $1, $2, $3}')
   token=$(echo $tokenpos | awk '{print $1}')
   count=$(echo $tokenpos | awk '{print $3}')
   pos=$(echo $tokenpos | awk '{print $2}')
   poscount=$(awk '$1 ~ /^'$pos'$/ {print $2}' train.IOB-POS.counts)
   if [ -z "$poscount" ]; then
       poscount=$(awk '$1 ~ /^\'$pos'$/ {print $2}' train.IOB-POS.counts)
   fi
   prob=$(echo "(( $count / $poscount ))" | bc -l)
   echo -e "$token\t$pos\t$prob"
done < train.TOK-IOB-POS.counts > output.temp

#-ln(prob) application
awk '{OFS="\t"; print $1, $2, -log($3)}' output.temp > train.TOK-IOB-POS.probs
echo "Done! Token - IOB - POS Tag file created!"

echo "Transducer generation..."
#transducer generation + tags add to lexicon
awk '{OFS="\t"; print 0, 0, $1 ,$2, $3} END {print 0}' train.TOK-IOB-POS.probs > train.TOK-IOB-POS.states
cat train.IOB-POS.counts | awk '{print $1}' >> train.symb
awk '{OFS="\t"; print $1, (NR-1)}' train.symb > train.temp
mv train.temp train.symb
numtags=$(cat train.IOB-POS.counts | awk '{print $1}' | wc -l)
#automa token-tag + <unk> generation
awk '{OFS="\t"; print 0, 0, "<unk>", $1, -log(1/296)} END {print 0}' train.IOB-POS.counts > train.unk.states
cat train.unk.states >> train.TOK-IOB-POS.states
awk '{print $0} END {print 0}' train.TOK-IOB-POS.states > train.total.states
fstcompile --isymbols=train.symb --osymbols=train.symb train.total.states > train.fst
echo "Done! Transducer created!"

#POS-per-sentence file generation, in order to create the automa corresponding to P(t(i) | t(i-1))
echo "POS - sentence language model generation with ngram order=$order, smoothing=$smooth..."
cat NLSPARQL.iob-pos | awk '{print $2}' | sed 's/^ *$/#/g' | tr '\n' ' ' | tr '#' '\n' | sed 's/^ *//g;s/ *$//g' > train.tags-phrase.lines
farcompilestrings --symbols=train.symb --unknown_symbol='<unk>' train.tags-phrase.lines > train.tags-phrase.far
ngramcount --order=$order --require_symbols=false train.tags-phrase.far > train.tags-phrase.cnt
ngrammake --method=$smooth train.tags-phrase.cnt > POS.lm
#test sentence file generation
paste NLSPARQL.test.data NLSPARQL.test.feats.txt | awk '{print $1, $2, $4}' > NLSPARQL.iob-pos.test
sed 's/\//-/g' NLSPARQL.iob-pos.test | awk 'NF==0 {print " "} NF==3 {print $1, $2"-"$3}' > iob-pos-test.temp
mv iob-pos-test.temp NLSPARQL.iob-pos.test
cat NLSPARQL.iob-pos.test | awk '{print $1}' | sed 's/^ *$/#/g' | tr '\n' ' ' | sed 's/^ *//g;s/ *$//g' > test.dict
tr '#' '\n' < test.dict | sed 's/^ *//g' > test.phrases
echo "Done! POS - sentence language model created! Ngram order=$order, Smoothing=$smooth"

echo "Sentence automatas generation..."
#test sentence automatons generation
cat test.phrases | farcompilestrings --symbols=train.symb --unknown_symbol='<unk>' --generate_keys=4 --keep_symbols | farextract --filename_suffix='.fst'
echo "Done! Sentences automatas created!"

echo "Transducer application for all sentence automatas"
#test performed on all the automatons
ls | grep '[0-9].*[0-9].*[0-9].*[0-9]' > filenames.txt
while read -r f
do
    index=$(echo "$f" | awk -F '.' '{print $1}')
    fstcompose "$index".fst train.fst | fstcompose - POS.lm | fstrmepsilon | fstshortestpath > test_$index.result.fst
    fstprint --isymbols=train.symb --osymbols=train.symb test_$index.result.fst | sort -nr | awk '{OFS="\t"; print $3, $4}' >> test.temp
done < filenames.txt
echo "Done! Transducer applied for all sentence automatas!"

echo "Almost done: creating the prediction file and parsing it to conlleval.pl!"
#file test.temp: token-corrected_pos - predicted_pos generation
paste NLSPARQL.iob-pos.test test.temp | awk '{OFS="\t"; print $1, $2, $4}' > test.labelled

echo "Creating the directory test_results, containing the previously created automatas..."
#a little of order...
mkdir -p test_results
while read -r f
do
    index=$(echo "$f" | awk -F '.' '{print $1}')
    mv $index.fst test_results/
    mv test_$index.result.fst test_results/
done < filenames.txt
echo "Done! Directory test_results created and populated!"

echo "Invoking conlleval.pl with the resulting output"
#invoking conlleval.pl for performance evaluation
chmod +x conlleval.pl
./conlleval.pl -d "\t" < test.labelled > log.print
cat log.print
cat log.print > result.POStag-$order-$smooth
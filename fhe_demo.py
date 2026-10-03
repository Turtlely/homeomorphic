'''
a toy example of homeomorphic encryption
a
we want to send the sentence "hello world" to a server, 
which will then securely capitalize all letters in that sentence.
Then it sends it back to us and we can decrypt the response to get "HELLO WORLD"
'''
from pprint import pprint
sentence = "hello world"

# in ascii
#print([f"{ord(x):08b}" for x in sentence])

#print(sentence.capitalize())
#print([f"{ord(x.capitalize()):08b}" for x in sentence])


# encrypting the sentence
p = 12345678 # secret key
r = 1 # random noise
q = 1 # random integer
m = 1
c_encrypt = q*p + 2*r + m # encryption
m_decrypt = (c_encrypt % p) % 2 # decryption

# encryption function
def encrypt(s, q, p, r):
    return [[q*p + 2*r + int(m) for m in f"{ord(l):008b}"] for l in s]


def decrypt(e, p):
    bits = [[str((b % p) % 2) for b in l] for l in e]
    return "".join([chr(int("".join(b), 2)) for b in bits])

def homeomorphic_capitalize(e):
    cout = []
    # for each letter in e
    for ew in e:
        cew = list(ew)
        cew[2] = cew[2] * (cew[1]+1)
        cout.append(cew)
    return cout


print(sentence)
e = encrypt(sentence, q, p, r)
print(e)
ce = homeomorphic_capitalize(e)

print(decrypt(ce, p))